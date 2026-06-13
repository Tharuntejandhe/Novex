# Homebrew cask for Novex.
#
# To offer `brew install`, create a tap repo named "homebrew-novex" under your
# GitHub account and drop this file in its Casks/ folder. Then users run:
#
#     brew install --cask <your-user>/novex/novex
#
# Update `version` and `sha256` on every release (sha256 of the released Novex.zip:
#   shasum -a 256 dist/Novex.zip).  Replace OWNER with your GitHub username.
cask "novex" do
  version "0.1.0"
  sha256 "4918fdd0e001407d7bc730f1bbbf6f4c956a7a75bde00dbc81fd1dc5c47c9e11"

  url "https://github.com/Tharuntejandhe/Novex/releases/download/v#{version}/Novex.zip"
  name "Novex"
  desc "On-device, private email assistant that lives in your menu bar"
  homepage "https://github.com/Tharuntejandhe/Novex"

  depends_on macos: :tahoe # macOS 26+ (minimum)

  app "Novex.app"

  caveats <<~EOS
    Novex is open-source and NOT notarized (no paid Apple Developer ID), so macOS
    will warn on first launch. Either:
      • right-click Novex.app → Open → Open, or
      • run:  xattr -dr com.apple.quarantine "#{appdir}/Novex.app"

    Novex reads Mail on-device and needs Full Disk Access:
      System Settings → Privacy & Security → Full Disk Access → enable Novex.

    The AI features need an Apple Silicon Mac on macOS 26+ with Apple
    Intelligence enabled. Everything is on-device — your mail never leaves your Mac.
  EOS
end
