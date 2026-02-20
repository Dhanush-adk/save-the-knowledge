cask "save-the-knowledge" do
  version "1.0.0"
  sha256 "REPLACE_WITH_RELEASE_ASSET_SHA256"

  url "https://github.com/YOUR_GITHUB_USER/knowledge-cache/releases/download/v#{version}/save-the-knowledge-macOS-v#{version}-bBUILD-unsigned.dmg",
      verified: "github.com/YOUR_GITHUB_USER/knowledge-cache/"
  name "Save the Knowledge"
  desc "Offline-first local knowledge base desktop app"
  homepage "https://github.com/YOUR_GITHUB_USER/knowledge-cache"

  depends_on macos: ">= :sonoma"

  app "Save the Knowledge.app"

  caveats <<~EOS
    This app is unsigned and not notarized.
    If macOS blocks launch, open System Settings -> Privacy & Security and allow it.
  EOS

  zap trash: [
    "~/Library/Application Support/KnowledgeCache",
    "~/Library/Containers/com.savetheknowledge.app",
    "~/Library/Preferences/com.savetheknowledge.app.plist",
    "~/Library/Saved Application State/com.savetheknowledge.app.savedState"
  ]
end
