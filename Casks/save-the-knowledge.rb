cask "save-the-knowledge" do
  version "1.1.8,16"
  sha256 "c07178456e9dfeb64667fb76fd60e3273344341117c18e7d6e9d6cc24aae7a6f"

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
