#!/bin/sh
set -e
mkdir -p /data /srv/acervo /home/acervo/.ssh
chown -R acervo /home/acervo /data
chmod 700 /home/acervo/.ssh
# Bytes aleatórios: cada subida precisa de hashes novos para não cair no índice de um teste anterior.
cd /srv/acervo
mkdir -p gba backup/gba gb
head -c 8192 /dev/urandom > gba/Alpha.gba
cp gba/Alpha.gba backup/gba/Alpha.gba
head -c 8192 /dev/urandom > gba/Beta.gba
head -c 8192 /dev/urandom > gb/Gamma.gb
echo notas > gba/readme.txt
ln -sf /nao/existe gba/quebrado.gba
smbd --daemon --no-process-group
/usr/sbin/sshd
export QUIET_SHELF_TOKEN=test-token QUIET_SHELF_ROOT=/srv/acervo QUIET_SHELF_DATA=/data/index.json QUIET_SHELF_RESCAN_MINUTES=1
exec python3 /usr/local/bin/shelf-service.py
