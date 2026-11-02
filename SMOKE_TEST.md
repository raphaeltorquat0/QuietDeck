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
| Shortcut visible in the Game Mode library | Passed |
| Shortcut launches RetroArch in Game Mode | Passed: the running AppId matched the shortcut |
| Devkit pairing, by request to `/register`, approved on the Deck | Passed |
| `steam://store` opens the Store in Game Mode | Passed |
| Quiet Clean rendered on the home by temporary injection | Passed |
| Focus stays on the featured cover with the theme | Passed |
| The pairing wizard in the app | Not run: the request was sent by hand |
| Pairing with a password, and setting one from the Mac | Not run: this Deck has no password |
| Anything with `sudo`: Decky install, plugins, reboot, shut down | Not run, same reason |
| Applying Quiet Clean without a password, then rebooting | Passed: loaded by CSS Loader, including over a light artwork |
| **Restore Valve Defaults** on the Deck | Not run: only on the simulated Deck |
| TabMaster tabs and sounds | Not run: TabMaster and Audio Loader aren't installed, and installing them needs `sudo` |
| Quiet Home after a real Steam restart: lands on the new home, real data, achievements on nine games, brand and focus ring, no error screen | Passed |
| Quiet Home D-pad left, right, up and down, L1 and R1, row scrolling | Passed with simulated input; physical controller not confirmed |
| Quiet Home download indicator and Play button | Not run |
| Loja tile inside Quiet Home | Rendered; opening it not run |
| Boot video and screensaver on screen | Not confirmed |
| microSD through the app | Not run: the test Deck's card failed with I/O errors before this work began, and came back at 14:16 on 2026-10-31 |
| OLED, BIOS import, artwork, CHD conversion on a real Deck | Not run |
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
- [ ] Drag a `.nsz` without keys: the job fails asking for `prod.keys`, and nothing reaches the Deck
- [ ] Drop your own Switch firmware (folder or `.zip` of `.nca` files): an "Install Switch firmware" job runs and Ryubing shows the firmware version
- [ ] Drop your own `prod.keys`, retry: it arrives as `.nsp` and opens in the emulator
- [ ] Drop a Switch translation pack (folder or `.zip` with `atmosphere/contents/<TitleID>/romfs`): an "Install" job puts it in Ryubing's mods and the game opens translated
- [ ] Drag a SNES ROM with its translation `.ips` or `.bps`: the card shows the patch, the game arrives as `ROM (patch).sfc` next to the original and opens translated
- [ ] Drag a PlayStation `.cue`/`.bin` with an `.xdelta`: it arrives as a translated `.chd`
- [ ] Drag a patch for another version: the job fails saying so, and nothing reaches the Deck
- [ ] Drag an extracted PS4 game folder (`CUSA…`): it shows the game title, arrives as `roms/ps4/Title [CUSA…]/` and opens fullscreen in shadPS4 from the home
- [ ] Drag a PS4 `.pkg`: the job fails asking for the extracted folder
- [ ] Settings › RetroAchievements: a wrong password shows the server's message; the right one shows "Signed in as" and a job turns achievements on in RetroArch and Dolphin
- [ ] Open a supported game from the home: the RetroAchievements login toast appears in the emulator
- [ ] Sign Out: achievements are off in both emulators and the token is gone from their settings
- [ ] Drag a file of an unknown format: the Library names it instead of ignoring it
- [ ] Send a Switch game with update, no game open: one shortcut, clean name, first on Quiet Home with focus
- [ ] Send with a game open: the game stays open, and the job finishes after it closes
- [ ] Send to the microSD: the shortcut opens the game
- [ ] Interrupt with Cancel, try again: it resumes
- [ ] Sending the same game again is skipped
- [ ] A two-disc game gets a `.m3u`
- [ ] Send to the microSD

## Decky, compat tools and saves

- [ ] Install Decky, and it opens in Game Mode with the `...` button
- [ ] Install and remove a plugin
- [ ] Install GE-Proton, and it appears in Steam's compatibility list after a restart
- [ ] Back up saves and restore them

## Quiet Home

- [ ] Install Quiet Home from Decky: the home shows the hero, one row of covers and the tabs
- [ ] The **Loja** tile is the last item of the row and opens the Store in Game Mode
- [ ] Removing the plugin brings the native home back
- [ ] Restart Steam with the plugin installed: it lands on Quiet Home with no Decky error screen
- [ ] Full pass with the physical controller, including Play, A on a cover and the Steam and `...` buttons
- [ ] The download indicator appears during an update, and only then
- [ ] Text keeps its contrast over three light artworks: snow, sky and a white background
- [ ] Full D-pad pass on the home, with no stuck or invisible focus: left and right along the row, up to the header, down, and the Steam and `...` buttons
- [ ] D-pad pass on the Library tabs with TabMaster: L1 and R1 switch tabs
- [ ] The boot video covers the whole boot, with no black screen after it
- [ ] Move, confirm and back have distinct sounds at the native volume
- [ ] The Quiet screensaver can be selected and runs on a pure black background
- [ ] **Restore Valve Defaults** brings back your CSS Loader themes, TabMaster, sounds, boot, screensaver and removes the Loja shortcut

## Non-destructive automated run

`Integration` tests delete `~/Emulation`, so **never point them at a real Deck**. Use the `RealDeck` suite, one step at a time: `record`, `transfer`, `flatpak`, `desktop`, `switch`, `game`, `survive`.

## Record the fixtures

- [ ] Remove anything personal from `recordings/*.json`, such as game names and your Steam ID
- [ ] Copy one to `Packages/DeckRemote/Tests/DeckRemoteTests/Fixtures/` and run `make test`

## Shelf (Phase 8)

Needs a collection on your network and a paired Deck. Nothing below has been run on a real Deck yet.

- [ ] Add a source in Settings › Shelf Sources, test the connection and scan. Repeat for each type you use: folder, SMB, NFS, SFTP/SSH, WebDAV, S3 (Backblaze B2, MinIO or Cloudflare R2), RomM and the service.
- [ ] Turn off one server. Its status turns red in the sidebar, and a game it shares with another source installs from that other one.
- [ ] Use a wrong password. The status says invalid credentials, not offline.
- [ ] From outside your network, connect to a source by its Tailscale address.
- [ ] Map a folder that doesn't follow the expected layout.
- [ ] Scan. Your games show up with the right systems, and copies count as one.
- [ ] Add ScreenScraper or IGDB credentials and scan again. Descriptions, covers and hero art show up.
- [ ] With a DAT in the folder shown in the Stocking Guide, a matching game shows **Matches your DAT**.
- [ ] Install 3 games from the collection, with **Add to Steam** on: one cartridge, one multi-track disc and one over the direct server → Deck path.
- [ ] In Game Mode, each of the 3 has its shortcut and artwork, and it opens.
- [ ] Remove all 3. Files, shortcuts and any `.m3u` are gone, and the Shelf shows them as not installed.
- [ ] Try a game larger than the free space. The warning names what to remove, and Install stays off.
- [ ] Install one item from **Free and Legal**. The license and official page links open.
- [ ] Service only: stop the Mac, restart the container and confirm that a Deck install started before still finished, and that `/index` answers 401 without the token.

## Quiet Glass

Nothing below has been run on a real Deck yet, except where marked.

- [x] Apply Quiet Glass from Decky. Your other themes stay on and Steam doesn't restart. The Decky service restarts, so the Steam side menus reload. Applied from the app on an LCD Deck, SteamOS 3.9.5.
- [x] Open the Steam menu and the quick access menu outside a game. Both show the theme, and the art behind them is blurred. The top and bottom bars are glass too. Checked with the theme copied by hand on an LCD Deck, SteamOS 3.9.5.
- [ ] Turn on **Vidro sempre** in QuietTune. The menu stays glass in a game, and the choice survives a reboot.
- [ ] Remove Quiet Glass. The theme and QuietTune are gone, and your other themes are as they were.

## Automatic glass switching

Read the active patch from CSS Loader after each step, not from the screen. `gamescopectl screenshot` only captures the game's plane while a game runs.

- [x] Open a Steam game. The patch goes to `Opaco`. Close it and it's back to `Vidro`. 1.7 s and 0.5 s on an LCD Deck, SteamOS 3.9.5, ReStory Playtest.
- [x] Repeat with a non-Steam shortcut (emulator or QuietDeck shortcut). 1.6 s and 3.8 s, RetroArch.
- [ ] Open a game, suspend the Deck, resume. The patch stays `Opaco`, and goes back to `Vidro` when you close the game.
- [ ] With a game open, run `sudo systemctl restart plugin_loader`. The patch is `Opaco` when Decky is back.
- [x] Kill the game process (`kill -9` on the `.exe`, not on `reaper`). Steam removes it from the running list and the patch returns to `Vidro`. 3.3 s on the real Deck, killing `reaper` too, so a game that hangs without exiting is still untested.

## Performance defaults

- [x] In QuietTune set TDP to 8 W and a fixed GPU clock of 1000 MHz. `power1_cap` reads 8000000 and `pp_od_clk_voltage` reads 1000 Mhz twice. Run through the Decky call on an LCD Deck, not the panel.
- [ ] Open a game. After a few seconds the profile is still there, even if Steam overwrote it.
- [x] Press **Restaurar padrão**. TDP is 15 W and the GPU level is `auto`. Run through the Decky call, not the panel. 16 W, 2 W and 1700 MHz were refused without touching sysfs.
- [ ] Write an out-of-range value in `~/homebrew/settings/QuietTune/performance.json` and restart Decky. The plugin restores the defaults and deletes the file.
- [ ] With a profile set, remove QuietTune from the app and again from the Decky store. Both restore the defaults.

## Measuring FPS and power draw

`scripts/perf/bench.mjs` runs this on battery, with no game open, and refuses to start otherwise. It needs the Deck's port 8080 forwarded to 127.0.0.1:9222, Quiet Glass present and `scripts/perf/sampler.py` copied to `/tmp/qd-sampler.py`. `scripts/perf/report.py` writes `docs/perf/quiet-glass.md`.

1. Choose 3 games: one heavy, close to the GPU limit; one light, capped at 60 FPS; one emulator or non-Steam shortcut. Record any substitution.
2. For each game, with MangoHud logging to a file (`mangohudctl set log_session 1`): 3 minutes with the quick access menu closed, 1 minute open in opaque mode, 1 minute open forcing glass. Run all of it twice.
3. Measure the idle home for 5 minutes each in the order glass, opaque, opaque, glass, in one block. Battery voltage falls during the run, so the order has to be symmetrical.
4. Power is battery current times voltage, because the Deck has no `power_now`, so samples only count while discharging. Keep the charger out.
   Only samples with the screen dimmed count: Steam dims it by itself after a few minutes and that alone changes the draw by almost 2 W, more than what's being measured. Each game waits up to about 10 minutes for the dim and carries on without it, since FPS and APU power don't depend on the screen.
   Steam rewrites `mangohud.config` when a game opens and drops `output_folder`, so the run adds it back before each block, with the game open.
   Opening a game doesn't reset Steam's 15-minute idle timer on battery. At that point it suspends, or turns the screen off if suspend is inhibited, and with no screen there are no frames. The run raises `system_idle_suspend_battery_sec` and puts it back at the end, even after a failure.
   The idle home needs 10 minutes of rest first: right after use it draws up to 1.3 W more with the same patch.
5. Pass: glass on the home and menus outside games costs no more than 0.3 W at idle. With the menu open in a game, record the FPS drop that justifies opaque as the default.

Status: done, see `docs/perf/quiet-glass.md`. The idle home passed. No game lost FPS with the menu open, but Solasta II stayed capped at 22 FPS, so the run doesn't rule out a small cost in a game without VSync.

Without a controller on the Deck the games stay on their title screens. The menu is opened through Steam's own API and checked with `GetOpenSideMenu()` and gamescope's input focus, since screenshots don't show it. Look at the Deck once during a run to confirm the menu is on screen.

