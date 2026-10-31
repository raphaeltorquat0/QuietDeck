#!/bin/bash
# Baixa a imagem de recovery oficial, liga o sshd e define a senha do deck ainda offline, e sobe em QEMU.
# `/etc` no SteamOS é um overlay cujo upperdir fica na partição var, então nada é gravado no rootfs.
# Sai quando a porta 2222 responde. Roda em Linux x86 com KVM.
set -euo pipefail
URL=https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2
IMG=steamos.img
[ -f "$IMG" ] || curl -fsSL "$URL" | bunzip2 > "$IMG"
truncate -s +8G "$IMG"

LOOP=$(sudo losetup --find --show --partscan "$IMG")
trap 'sudo losetup -d "$LOOP" || true' EXIT
sudo partprobe "$LOOP" || true
lsblk "$LOOP"
HASH=$(openssl passwd -6 quietdeck)
MNT=$(mktemp -d)
SHADOW=$(mktemp)
# Primeiro acha o rootfs (só leitura) para copiar o shadow original com a senha do deck trocada.
for part in "$LOOP"p*; do
  sudo mount -o ro "$part" "$MNT" 2>/dev/null || continue
  if sudo test -f "$MNT/etc/shadow"; then sudo sed "s|^deck:[^:]*:|deck:$HASH:|" "$MNT/etc/shadow" > "$SHADOW"; fi
  sudo umount "$MNT"
done
[ -s "$SHADOW" ] || { echo "rootfs não encontrado na imagem" >&2; exit 1; }
FOUND=0
for part in "$LOOP"p*; do
  sudo mount "$part" "$MNT" 2>/dev/null || continue
  if sudo test -d "$MNT/lib" && sudo test ! -f "$MNT/etc/shadow"; then
    UP="$MNT/lib/overlays/etc/upper"
    sudo mkdir -p "$UP/systemd/system/multi-user.target.wants" "$MNT/lib/overlays/etc/work"
    sudo ln -sf /usr/lib/systemd/system/sshd.service "$UP/systemd/system/multi-user.target.wants/sshd.service"
    sudo install -m 600 "$SHADOW" "$UP/shadow"
    FOUND=1
  fi
  sudo umount "$MNT"
done
[ "$FOUND" = 1 ] || { echo "partição var não encontrada na imagem" >&2; exit 1; }
sudo losetup -d "$LOOP"
trap - EXIT

cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd
qemu-system-x86_64 -enable-kvm -cpu host -smp 2 -m 4096 -serial file:qemu.log \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive if=virtio,format=raw,file="$IMG" \
  -device virtio-net-pci,netdev=n0 -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -daemonize -pidfile qemu.pid -display none

for _ in $(seq 1 180); do
  if ssh-keyscan -T 3 -p 2222 127.0.0.1 2>/dev/null | grep -q ssh; then echo "SteamOS responde na 2222"; exit 0; fi
  sleep 10
done
echo "SSH não subiu em 30 min" >&2
exit 1
