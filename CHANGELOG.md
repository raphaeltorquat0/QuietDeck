# Changelog

## [Unreleased]

### Changed

- **Requires macOS 26.** The interface now uses native Liquid Glass for navigation and controls, while content stays opaque.
- The app icon has light, dark, tinted and clear variants.

### Added

- **Quiet Glass** for Game Mode: glass on the top and bottom bars, the home tabs and the Steam and quick access menus. The new QuietTune plugin makes the menus opaque while a game runs, unless you force glass.
- **Shelf**: a storefront over your own collection, from any mix of folders, SMB, NFS, SFTP/SSH, WebDAV, S3-compatible buckets, RomM servers or an optional container service, with priorities, status in the sidebar and network discovery. Incremental hashing, your own No-Intro/Redump DATs, deduplication, filters, details and one-click install and remove.
- Direct server → Deck transfers when there's nothing to process on the Mac.
- Descriptions and artwork from ScreenScraper and IGDB with your own credentials. QuietDeck never downloads game files from them.
- **Free and Legal**: a catalog of homebrew with verified licenses, downloaded from official sources and checked by SHA-256 (see `CATALOG.md`).
- Stocking Guide for dumping your own cartridges and discs.

## 0.1.0

First release. Everything below has been tested against a simulated Deck. [SMOKE_TEST.md](SMOKE_TEST.md) lists what has also been checked on a real one.

- Pair with a Deck through Valve's devkit service, with no keyboard and no Desktop Mode, or manually as a fallback
- Set the `deck` password from the Mac when it has none
- Overview with SteamOS version, battery, storage, temperature and session mode
- Install, update and remove emulators as user Flatpaks, and set their ROM and BIOS paths
- BIOS status per system, with import checked against known hashes
- ROM pipeline: detect the system, extract, convert to CHD, create .m3u, skip duplicates and send to internal storage or microSD
- Add non-Steam shortcuts safely, with a backup and SteamGridDB artwork
- Decky Loader and plugin store
- GE-Proton and Proton-CachyOS
- Save backup and restore
- Quick actions, a persistent job queue and an optional menu bar extra
- Quiet Home, a Decky plugin that gives Game Mode a calmer home with real playtime and achievements
- Command palette, cover grid, Liquid Glass and English and Brazilian Portuguese
