cask "quietdeck" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/raphaeltorquat0/QuietDeck/releases/download/v#{version}/QuietDeck-#{version}.dmg"
  name "QuietDeck"
  desc "Manage a Steam Deck from your Mac over SSH"
  homepage "https://github.com/raphaeltorquat0/QuietDeck"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "QuietDeck.app"

  uninstall quit: "io.github.raphaeltorquat0.QuietDeck"

  zap trash: [
    "~/Library/Application Support/QuietDeck",
    "~/Library/Preferences/io.github.raphaeltorquat0.QuietDeck.plist",
    "~/.ssh/quietdeck_ed25519",
    "~/.ssh/quietdeck_ed25519.pub",
  ]
end
