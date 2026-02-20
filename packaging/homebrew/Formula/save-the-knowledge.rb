class SaveTheKnowledge < Formula
  desc "Offline-first local knowledge base desktop app for macOS"
  homepage "https://github.com/YOUR_GITHUB_USER/knowledge-cache"
  url "https://github.com/YOUR_GITHUB_USER/knowledge-cache/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_SOURCE_TARBALL_SHA256"
  license "MIT"

  depends_on macos: :sonoma

  def install
    derived = buildpath/"build/HomebrewDerivedData"
    app_path = derived/"Build/Products/Release/Save the Knowledge.app"

    system "xcodebuild",
           "-project", "KnowledgeCache.xcodeproj",
           "-scheme", "KnowledgeCache",
           "-configuration", "Release",
           "-destination", "platform=macOS",
           "-derivedDataPath", derived,
           "CODE_SIGNING_ALLOWED=NO",
           "CODE_SIGNING_REQUIRED=NO",
           "build"

    prefix.install app_path
    bin.write_exec_script prefix/"Save the Knowledge.app/Contents/MacOS/Save the Knowledge"
  end

  def caveats
    <<~EOS
      App bundle installed at:
        #{opt_prefix}/Save the Knowledge.app

      Launch with:
        open "#{opt_prefix}/Save the Knowledge.app"

      This build is unsigned and not notarized.
      On first launch, macOS may require manual approval in Privacy & Security.
    EOS
  end
end
