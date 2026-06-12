# Homebrew cask for Crux.
#
# To offer `brew install`, create a tap repo named "homebrew-crux" under your
# GitHub account and drop this file in its Casks/ folder. Then users run:
#
#     brew install --cask <your-user>/crux/crux
#
# Update `version` and `sha256` on every release (sha256 of the released Crux.zip:
#   shasum -a 256 dist/Crux.zip).  Replace OWNER with your GitHub username.
cask "crux" do
  version "0.1.0"
  sha256 "08911dcaa64f9255cd9546ea8331accaafbec9d6f616b1d6de12257145f4ff60"

  url "https://github.com/Tharuntejandhe/Crux/releases/download/v#{version}/Crux.zip"
  name "Crux"
  desc "On-device, private email assistant that lives in your menu bar"
  homepage "https://github.com/Tharuntejandhe/Crux"

  depends_on macos: ">= :tahoe" # macOS 26+

  app "Crux.app"

  caveats <<~EOS
    Crux is open-source and NOT notarized (no paid Apple Developer ID), so macOS
    will warn on first launch. Either:
      • right-click Crux.app → Open → Open, or
      • run:  xattr -dr com.apple.quarantine "#{appdir}/Crux.app"

    Crux reads Mail on-device and needs Full Disk Access:
      System Settings → Privacy & Security → Full Disk Access → enable Crux.

    The AI features need an Apple Silicon Mac on macOS 26+ with Apple
    Intelligence enabled. Everything is on-device — your mail never leaves your Mac.
  EOS
end
