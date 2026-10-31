# Free and Legal catalog

The catalog lives in `Packages/DeckKit/Sources/DeckKit/Resources/free-catalog.json`. It lists homebrew
and freeware that QuietDeck downloads from the official source, never from a mirror of ours.

## Rules

An item only gets in if all of these are true:

1. Its license allows redistribution, and you've read that license in the project itself. A store page or wiki saying so isn't enough.
2. The license covers the game's assets as well as its code. NonCommercial terms don't qualify.
3. It has a stable, direct download from the author, such as a GitHub release asset.
4. You've downloaded the file and computed its SHA-256 yourself.

`FreeCatalogTests` rejects an item without a license, an HTTPS link for each URL, a valid hash or a known system.
A commercial game, ROM set or BIOS never qualifies, whatever a page says about it.

## Adding an item

1. Check the rules against the official source.
2. Add the entry, with `license` as an SPDX expression and `licenseURL` pointing at the license file.
3. For a `.zip`, set `inner` to the main file inside it.
4. Run `scripts/fetch-fixtures.sh`, which fails if a hash doesn't match, then `make test`.
5. Open a pull request linking to the license and the release.

An author replacing a release file changes its hash. The install then fails safely until the entry is updated.

## Left out

| Item | Why |
|---|---|
| 240p Test Suite builds for Genesis, SNES, N64, Dreamcast, Wii, GameCube, PC Engine, Neo Geo | No stable direct download: they're published on itch.io only. Their license notices also differ between itch.io and the repository. Get them from the [official page](https://artemiourbina.itch.io/240p-test-suite). |
| 240p Test Suite for Sega CD | Its loader isn't under the GPL, so third-party redistribution is unclear. |
| Tobu Tobu Girl, Super Tilt Bro. | No stable direct download. Super Tilt Bro. also needs a mapper that stock emulators may not support. |
| Nova the Squirrel | Its assets are NonCommercial. |
| Anguna, Blade Buster, Twin Dragons | No license could be verified. |
