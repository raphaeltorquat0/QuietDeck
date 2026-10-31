# Security

QuietDeck talks to your Steam Deck over SSH on your local network with a dedicated key (`~/.ssh/quietdeck_ed25519`). The `deck` password stays in your Keychain and is only sent to `sudo -S` on the Deck, over SSH, when an action needs it.

## Report a vulnerability

Don't open a public issue. Use [Report a vulnerability](https://github.com/raphaeltorquat0/QuietDeck/security/advisories/new) on GitHub, with the affected version and the steps to reproduce.

This is a project maintained by one person in their spare time, so there's no guaranteed response time.

## Supported versions

Only the latest release receives fixes.
