import Foundation

@MainActor
final class AppUpdateManager: ObservableObject {
    @Published var isChecking = false
    @Published var isUpgrading = false
    @Published var isUpdateAvailable = false
    @Published var statusMessage = "Not checked yet."
    @Published var latestVersionLabel: String?

    private var activeShellProcess: Process?

    private let owner = "Dhanush-adk"
    private let repo = "save-the-knowledge"
    private let tap = "Dhanush-adk/save-the-knowledge"
    private let cask = "save-the-knowledge"

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
                statusMessage = "Update available: \(release.displayLabel)"
            } else {
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
        statusMessage = "Upgrading app with Homebrew..."
        defer {
            isUpgrading = false
            activeShellProcess = nil
        }

        let command = """
        if command -v brew >/dev/null 2>&1; then BREW=brew; \
        elif [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew; \
        elif [ -x /usr/local/bin/brew ]; then BREW=/usr/local/bin/brew; \
        else echo '__BREW_NOT_FOUND__'; exit 127; fi
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
            if output.contains("__brew_not_found__") || output.contains("command not found") {
                statusMessage = "Homebrew not found. Install Homebrew, then retry."
            } else if output.contains("cancelled") || output.contains("terminated") {
                statusMessage = "Upgrade cancelled."
            } else {
                statusMessage = "Upgrade failed. Open Terminal and run: brew reinstall --cask \(cask)"
            }
            return
        }

        statusMessage = "Upgrade complete. Restart app to use the newest version."
        await checkForUpdates()
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

        return ReleaseInfo(version: version, build: build)
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

private struct ReleaseInfo {
    let version: String
    let build: Int?

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
}
