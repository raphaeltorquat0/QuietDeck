#!/bin/bash
# PID 1 do Deck simulado: sshd, repositório flatpak local e a sessão falsa do Steam.
set -e
build-flatpak-repo.sh
mkdir -p /run/deck-sim /run/user/1000 && chmod 777 /run/deck-sim && chown deck /run/user/1000
echo game > /run/deck-sim/session
touch /run/deck-sim/systemctl.log /run/deck-sim/steam.log && chmod 666 /run/deck-sim/*
su deck -c '
  flatpak remote-add --user --no-gpg-verify --if-not-exists flathub /srv/flatpak-repo
  mkdir -p ~/.local/share/Steam/userdata/12345/config ~/.local/share/Steam/userdata/0/config ~/.steam
  ln -sfn ~/.local/share/Steam ~/.steam/steam
  ln -sfn ~/.local/share/Steam ~/.steam/root
  seed-shortcuts.py ~/.local/share/Steam/userdata/12345/config/shortcuts.vdf
  nohup gamescope-supervisor >/tmp/supervisor.log 2>&1 &
'
exec /usr/sbin/sshd -D -e
