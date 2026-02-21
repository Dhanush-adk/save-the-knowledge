import Foundation
import AppKit

@MainActor
final class AppUpdateManager: ObservableObject {
    @Published var isChecking = false
    @Published var isUpgrading = false
    @Published var isUpdateAvailable = false
    @Published var restartRequiredAfterUpgrade = false
    @Published var statusMessage = "Not checked yet."
    @Published var latestVersionLabel: String?

    private var activeShellProcess: Process?

    private let owner = "Dhanush-adk"
    private let repo = "save-the-knowledge"
    private let tap = "Dhanush-adk/save-the-knowledge"
    private let cask = "save-the-knowledge"
    private let appDisplayName = "Save the Knowledge"

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        statusMessage = "Checking for updates..."

        do {
            let release = try await fetchLatestRelease()
            latestVersionLabel = release.displayLabel
            if isReleaseNewerThanCurrent(release) {
                isUpdateAvailable = true
                statusMessage = restartRequiredAfterUpgrade
                    ? "Restart did not switch to the latest app yet. Update still available: \(release.displayLabel)"
                    : "Update available: \(release.displayLabel)"
            } else {
                restartRequiredAfterUpgrade = false
                isUpdateAvailable = false
                statusMessage = "Up to date (\(currentDisplayVersion()))."
            }
        } catch {
            isUpdateAvailable = false
            statusMessage = "Could not check updates."
            AppLogger.warning("Updater: check failed - \(error.localizedDescription)")
        }
    }

    func upgradeToLatest() async {
        guard !isUpgrading else { return }
        isUpgrading = true
        statusMessage = "Preparing upgrade..."
        defer {
            isUpgrading = false
            activeShellProcess = nil
        }

        let release: ReleaseInfo
        do {
            release = try await fetchLatestRelease()
            latestVersionLabel = release.displayLabel
        } catch {
            statusMessage = "Could not fetch latest release."
            AppLogger.warning("Updater: latest release fetch failed - \(error.localizedDescription)")
            return
        }

        guard isReleaseNewerThanCurrent(release) else {
            restartRequiredAfterUpgrade = false
            isUpdateAvailable = false
            statusMessage = "Up to date (\(currentDisplayVersion()))."
            return
        }

        guard let brewPath = resolveHomebrewPath() else {
            statusMessage = "Homebrew not found. Downloading installer DMG..."
            let outcome = await downloadAndInstallFromDMG(for: release)
            switch outcome {
            case .installed:
                restartRequiredAfterUpgrade = true
                isUpdateAvailable = false
                statusMessage = "Upgrade installed automatically. Restart app to finish update."
            case .opened(let dmgPath):
                statusMessage = """
                Installer ready.
                1) Quit the app.
                2) Open \(dmgPath.lastPathComponent) and drag \(appDisplayName).app to Applications.
                3) Replace existing app, then reopen.
                """
            case .failed:
                statusMessage = "Could not open installer DMG. Download from GitHub Releases."
            }
            return
        }

        statusMessage = "Upgrading app with Homebrew..."

        let command = """
        BREW="\(brewPath)"
        "$BREW" tap \(tap) >/dev/null 2>&1 || true
        "$BREW" update
        if "$BREW" list --cask \(cask) >/dev/null 2>&1; then
          "$BREW" upgrade --cask \(cask) || "$BREW" reinstall --cask \(cask)
        else
          "$BREW" install --cask \(cask)
        fi
        """

        let result = await runShell(command)
        if !result.success {
            let output = result.output.lowercased()
            if output.contains("cancelled") || output.contains("terminated") {
                statusMessage = "Upgrade cancelled."
            } else {
                statusMessage = "Upgrade failed. Open Terminal and run: brew reinstall --cask \(cask)"
            }
            return
        }

        restartRequiredAfterUpgrade = true
        isUpdateAvailable = false
        statusMessage = "Upgrade installed. Restart app to finish update."
    }

    func cancelUpgrade() {
        guard let process = activeShellProcess, process.isRunning else { return }
        process.terminate()
        statusMessage = "Cancelling upgrade..."
    }

    private func currentDisplayVersion() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "v\(version) (\(build))"
    }

    private func isReleaseNewerThanCurrent(_ release: ReleaseInfo) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let currentVersion = info["CFBundleShortVersionString"] as? String ?? "0"
        let currentBuildString = info["CFBundleVersion"] as? String ?? "0"
        let currentBuild = Int(currentBuildString) ?? 0

        let versionCompare = currentVersion.compare(release.version, options: .numeric)
        if versionCompare == .orderedAscending { return true }
        if versionCompare == .orderedDescending { return false }

        if let latestBuild = release.build {
            return currentBuild < latestBuild
        }
        return false
    }

    private func resolveHomebrewPath() -> String? {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func downloadAndOpenDMG(for release: ReleaseInfo) async -> Bool {
        let outcome = await downloadAndInstallFromDMG(for: release)
        if case .opened = outcome { return true }
        if case .installed = outcome { return true }
        return false
    }

    private func downloadAndInstallFromDMG(for release: ReleaseInfo) async -> DMGUpgradeOutcome {
        guard let downloadURL = release.dmgDownloadURL else { return .failed }
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 180

        do {
            let (tmpURL, response) = try await URLSession.shared.download(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return .failed }

            let fm = FileManager.default
            let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
            let fileName = release.dmgAssetName ?? "save-the-knowledge-update.dmg"
            let destination = downloads.appendingPathComponent(fileName)

            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tmpURL, to: destination)

            if await tryInstallDMG(at: destination) {
                return .installed
            }

            guard NSWorkspace.shared.open(destination) else { return .failed }
            return .opened(destination)
        } catch {
            AppLogger.warning("Updater: dmg download/open failed - \(error.localizedDescription)")
            return .failed
        }
    }

    private func tryInstallDMG(at dmgURL: URL) async -> Bool {
        let dmgPath = shellEscape(dmgURL.path)
        let targetPath = shellEscape("/Applications/\(appDisplayName).app")
        let appName = shellEscape("\(appDisplayName).app")
        let command = """
        set -e
        MOUNT_POINT="$(hdiutil attach -nobrowse \(dmgPath) 2>/dev/null | awk '/\\/Volumes\\// {line=$0} END {sub(/^.*\\t/, \"\", line); print line}')"
        if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
          exit 1
        fi
        APP_SRC="$(find "$MOUNT_POINT" -maxdepth 2 -name \(appName) -print -quit)"
        if [ -z "$APP_SRC" ]; then
          hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
          exit 1
        fi
        osascript -e 'on run argv' \
                  -e 'set srcPath to item 1 of argv' \
                  -e 'set dstPath to item 2 of argv' \
                  -e 'do shell script "ditto " & quoted form of srcPath & space & quoted form of dstPath with administrator privileges' \
                  -e 'end run' \
                  "$APP_SRC" \(targetPath)
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
        """
        let result = await runShell(command)
        return result.success
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = decoded.tagName.replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let dmg = decoded.assets.first(where: { $0.name.localizedCaseInsensitiveContains(cask) && $0.name.lowercased().hasSuffix(".dmg") })
        let build = dmg.flatMap { Self.extractBuild(fromAssetName: $0.name) }
        return ReleaseInfo(
            version: version,
            build: build,
            dmgAssetName: dmg?.name,
            dmgDownloadURL: dmg.flatMap { URL(string: $0.browserDownloadURL) }
        )
    }

    private static func extractBuild(fromAssetName name: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "-b([0-9]+)", options: []) else { return nil }
        let ns = name as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: name, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        let buildString = ns.substring(with: match.range(at: 1))
        return Int(buildString)
    }

    private func runShell(_ command: String) async -> (success: Bool, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Task { @MainActor [weak self] in
                    if self?.activeShellProcess === proc {
                        self?.activeShellProcess = nil
                    }
                }
                continuation.resume(returning: (proc.terminationStatus == 0, (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)))
            }

            do {
                try process.run()
                activeShellProcess = process
            } catch {
                continuation.resume(returning: (false, error.localizedDescription))
            }
        }
    }
}

private enum DMGUpgradeOutcome {
    case installed
    case opened(URL)
    case failed
}

private struct ReleaseInfo {
    let version: String
    let build: Int?
    let dmgAssetName: String?
    let dmgDownloadURL: URL?

    var displayLabel: String {
        if let build {
            return "v\(version) (\(build))"
        }
        return "v\(version)"
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
