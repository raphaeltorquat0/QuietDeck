# Changelog

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
