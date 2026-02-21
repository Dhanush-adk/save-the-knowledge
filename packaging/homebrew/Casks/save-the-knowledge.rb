cask "save-the-knowledge" do
  version "1.1.4,12"
  sha256 "4e59c2a4d9b28d6756998dc2e7a8c43cfd552ff92b861a15a34e01371262c2dd"

  url "https://github.com/Dhanush-adk/save-the-knowledge/releases/download/v#{version.csv.first}/save-the-knowledge-macOS-v#{version.csv.first}-b#{version.csv.second}-unsigned.dmg",
      verified: "github.com/Dhanush-adk/save-the-knowledge/"
  name "Save the Knowledge"
  desc "Offline-first local knowledge base desktop app"
  homepage "https://github.com/Dhanush-adk/save-the-knowledge"

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
