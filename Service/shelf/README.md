# Shelf service

Optional container that keeps the Shelf index up to date on a server and serves the files on your
local network, so the Mac doesn't have to stay on. It only reads your collection folder.

## Deploy

```sh
cd Service/shelf
ACERVO=/srv/games QUIET_SHELF_TOKEN=$(openssl rand -hex 32) docker compose up -d --build
```

Keep the token: it goes in QuietDeck › Settings › Shelf Sources, with `http://<server>:8766`.
The collection is laid out as `<collection>/<system>/<files>`, and the first scan hashes everything,
so it can take hours on a large collection. Games show up while it runs.

## Security

- Traffic is plain HTTP. Use it only on a network you trust, and never expose the port to the internet.
- Every request except `/health` needs the token. Without `QUIET_SHELF_TOKEN` the service doesn't start.
- Paths are resolved and checked against the collection folder, which is mounted read-only.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `QUIET_SHELF_TOKEN` | required | Bearer token |
| `QUIET_SHELF_RESCAN_MINUTES` | `60` | Time between scans |
| `QUIET_SHELF_PORT` | `8766` | Listening port |
