# Deck simulado para os testes de integração: Arch, sshd, flatpak e sudo com senha em /home/deck.
# `archlinux` só existe em amd64, e o sshd não roda em amd64 emulado (o Rosetta não tem seccomp).
# Em Mac ARM: --build-arg BASE=menci/archlinuxarm:base (ver Makefile).
ARG BASE=archlinux:latest
FROM ${BASE}
# Em container o sandbox do pacman nem sempre tem as syscalls de que precisa.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
 && pacman -Syu --noconfirm --needed openssh sudo flatpak rsync python jq curl procps-ng which ostree unzip tar \
 && rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*
RUN useradd -m -u 1000 -s /bin/bash deck && echo 'deck:deck-password' | chpasswd \
 && printf 'deck ALL=(ALL) ALL\nDefaults timestamp_timeout=0\nDefaults lecture=never\n' > /etc/sudoers.d/deck \
 && useradd -m -s /bin/bash nopass && passwd -d nopass \
 && ssh-keygen -A \
 && printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication no\nUsePAM yes\nMaxStartups 100\nMaxSessions 100\n' > /etc/ssh/sshd_config.d/deck.conf
COPY os-release /etc/os-release
COPY steam /usr/bin/steam
COPY systemctl /usr/bin/systemctl
COPY devkit-service.py gamescope-supervisor systemd-run steamos-session-select deck-sim seed-shortcuts.py entrypoint.sh build-flatpak-repo.sh /usr/local/bin/
RUN chmod +x /usr/bin/steam /usr/bin/systemctl /usr/local/bin/* \
 && ln -s steamos-session-select /usr/local/bin/steamosctl \
 && cp /usr/bin/sleep /usr/local/bin/plasmashell
EXPOSE 22 32000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
