# Contributing

Issues and pull requests are welcome in English or Portuguese.

## Setup

You need macOS 26 or later, Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The integration tests also need Docker.

```sh
make test          # unit and replay tests
make integration   # against a simulated Deck in Docker
make dev           # run the app in Debug
```

## How it fits together

- `Packages/DeckKit`: pure logic and the versioned catalogs in `Resources/`
- `Packages/DeckRemote`: SSH, transfers and every operation on the Deck
- `Harness/`: the simulated Deck, including the fake Steam that rewrites `shortcuts.vdf` on exit
- `App/`: the SwiftUI app

Both packages build on Linux, so CI can run the integration tests next to Docker.

## Rules

- Every operation reads the real state on the Deck before acting, and running it twice changes nothing.
- Nothing writes to the rootfs or uses pacman. The exceptions are listed in `DECISIONS.md`.
- ROMs, BIOS and firmware are never downloaded.
- Add a test for new behavior, and record ambiguous choices in `DECISIONS.md`.
- Write commit messages in Portuguese or English, in the imperative.

## Add an emulator

Edit `Packages/DeckKit/Sources/DeckKit/Resources/emulators.json`. Confirm the app id against the Flathub list, because `/api/v2/appstream/<id>` also answers for removed apps.
