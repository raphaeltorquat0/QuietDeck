#!/bin/bash
# Repositório flatpak mínimo com o nome `flathub`: os testes não dependem de baixar runtimes reais.
set -e
W=$(mktemp -d); cd "$W"; ARCH=$(flatpak --default-arch)
mkdir -p rt/usr app/files/bin app/export
echo runtime > rt/usr/marker
printf '[Runtime]\nname=org.quietdeck.Platform\nruntime=org.quietdeck.Platform/%s/1\nsdk=org.quietdeck.Platform/%s/1\n' "$ARCH" "$ARCH" > rt/metadata
flatpak build-export --runtime --files=usr /srv/flatpak-repo rt 1 >/dev/null
printf '#!/bin/sh\necho hello\n' > app/files/bin/hello; chmod +x app/files/bin/hello
printf '[Application]\nname=org.quietdeck.Hello\nruntime=org.quietdeck.Platform/%s/1\ncommand=hello\n' "$ARCH" > app/metadata
flatpak build-export /srv/flatpak-repo app stable >/dev/null
chmod -R a+rX /srv/flatpak-repo
rm -rf "$W"
