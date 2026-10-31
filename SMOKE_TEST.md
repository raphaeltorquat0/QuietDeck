# Smoke test

Run this on a real Deck before each release. The automated tests use a simulated Deck, which can't prove how SteamOS itself behaves.

Open the app with recording on, so the run also produces fixtures:

```sh
open dist/QuietDeck.app --args --record "$PWD/recordings"
```

## Onboarding

- [ ] With no Decks saved, the three-step onboarding appears
- [ ] The Deck shows up in step 1, or works with a typed IP address
- [ ] Both commands in step 2 copy correctly and work in Konsole
- [ ] Step 3 connects with the password, and `ssh -i ~/.ssh/quietdeck_ed25519 deck@<ip> true` works without one
- [ ] Reopening the app doesn't show onboarding

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

## Record the fixtures

- [ ] Remove anything personal from `recordings/*.json`, such as game names and your Steam ID
- [ ] Copy one to `Packages/DeckRemote/Tests/DeckRemoteTests/Fixtures/` and run `make test`
