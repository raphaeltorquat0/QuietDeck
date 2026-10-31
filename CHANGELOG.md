# Changelog

## 0.1.0

First release. Everything below has been tested against a simulated Deck; see [SMOKE_TEST.md](SMOKE_TEST.md) for what still needs a real one.

- Pair with a Deck over SSH using a dedicated key, with Bonjour discovery and manual IP
- Overview with SteamOS version, battery, storage, temperature and session mode
- Install, update and remove emulators as user Flatpaks, and set their ROM and BIOS paths
- BIOS status per system, with import checked against known hashes
- ROM pipeline: detect the system, extract, convert to CHD, create .m3u, skip duplicates and send to internal storage or microSD
- Add non-Steam shortcuts safely, with a backup and SteamGridDB artwork
- Decky Loader and plugin store
- GE-Proton and Proton-CachyOS
- Save backup and restore
- Quick actions, a persistent job queue and an optional menu bar extra
