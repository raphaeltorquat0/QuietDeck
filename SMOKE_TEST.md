# Smoke test

Run this on a real Deck before each release. The automated tests use a simulated Deck, which can't prove how SteamOS itself behaves.

Open the app with recording on, so the run also produces fixtures:

```sh
open dist/QuietDeck.app --args --record "$PWD/recordings"
```

## Last run

Steam Deck LCD, SteamOS 3.9.5 (build 20261023.100), 2026-10-31, through `QUIETDECK_REAL_DECK=<host> QUIETDECK_REAL_STEP=<step> swift test --filter RealDeck`.

| Check | Result |
|---|---|
| Overview data: version, battery, storage, temperature, mode | Passed |
| rsync upload from macOS with a space and an apostrophe, hash matches | Passed |
| RetroArch installed as a user Flatpak, adding the user `flathub` remote | Passed |
| Shortcut in Desktop Mode: Steam stops and comes back | Passed |
| Shortcut in Game Mode: mask, stop, write, unmask, start | Passed |
| Both shortcuts survive another Steam restart | Passed |
| Backup of `shortcuts.vdf` | Passed |
| Switch to Game Mode | Passed |
| Shortcut visible in the Game Mode library and launches | Not confirmed |
| Pairing with a password, in the app | Not run: the password was unknown, so the key was installed by hand |
| Anything with `sudo`: Decky install, plugins, reboot, shut down | Not run, same reason |
| microSD, OLED, BIOS import, artwork, CHD conversion on a real Deck | Not run |
| App UI connected to a real Deck | Not run |

## Onboarding

- [ ] With no Decks saved, the three-step onboarding appears
- [ ] The Deck shows up in step 1, or works with a typed IP address
- [ ] Both commands in step 2 copy correctly and work in Konsole
- [ ] Step 3 connects with the password, and `ssh -i ~/.ssh/quietdeck_ed25519 deck@<ip> true` works without one
- [ ] Reopening the app doesn't show onboarding

## Devkit pairing

This flow can't be simulated: the approval happens inside Steam. Test on a current SteamOS with SSH off.

- [ ] With no Decks saved, the wizard finds the Deck through `_steamos-devkit._tcp`
- [ ] Without Developer Mode, the wizard asks for it and moves on by itself once it's on
- [ ] It asks for Settings › Developer › Pair new host and moves on by itself
- [ ] The request appears on the Deck, and approving it finishes pairing without touching the Deck's keyboard
- [ ] Denying it shows the manual path with copyable commands
- [ ] Installing Decky on a `deck` user with no password offers to set one from the Mac

## Overview

- [ ] SteamOS version, battery, storage and temperatures match the Deck
- [ ] Mode reads Game Mode, and Desktop Mode after switching
- [ ] The microSD appears when inserted

## Install an emulator

- [ ] Create Emulation Folders makes `~/Emulation`
- [ ] Install RetroArch from Emulators, and the version appears
- [ ] Set Paths writes `retroarch.cfg`, and asks before changing an existing one
- [ ] Remove takes it away

## Add a shortcut

This is the check that matters most. It proves the systemd sequence in `DECISIONS.md` #14 on real hardware.

- [ ] In **Game Mode**, send a ROM from the Library with **Add to Steam when done**
- [ ] The app warns that the running game will close
- [ ] Steam restarts by itself, without a black screen
- [ ] **The game appears in the Game Mode library under Non-Steam**
- [ ] It launches
- [ ] After restarting Steam, the game is still there
- [ ] `shortcuts.vdf.quietdeck-*.bak` exists next to `shortcuts.vdf`
- [ ] Repeat in Desktop Mode
- [ ] Artwork chosen in the preview appears in the library

## Transfers

- [ ] Drag a folder with `.cue` and `.bin` for PlayStation: it arrives as `.chd`
- [ ] Interrupt with Cancel, try again: it resumes
- [ ] Sending the same game again is skipped
- [ ] A two-disc game gets a `.m3u`
- [ ] Send to the microSD

## Decky, compat tools and saves

- [ ] Install Decky, and it opens in Game Mode with the `...` button
- [ ] Install and remove a plugin
- [ ] Install GE-Proton, and it appears in Steam's compatibility list after a restart
- [ ] Back up saves and restore them

## Non-destructive automated run

`Integration` tests delete `~/Emulation`, so **never point them at a real Deck**. Use the `RealDeck` suite, one step at a time: `record`, `transfer`, `flatpak`, `desktop`, `switch`, `game`, `survive`.

## Record the fixtures

- [ ] Remove anything personal from `recordings/*.json`, such as game names and your Steam ID
- [ ] Copy one to `Packages/DeckRemote/Tests/DeckRemoteTests/Fixtures/` and run `make test`
