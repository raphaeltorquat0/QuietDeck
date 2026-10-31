# Decisões

Registro das escolhas feitas onde a especificação era ambígua. Regra geral: na dúvida, a opção mais
conservadora (menos escrita no Deck, menos permissão, menos dependência).

| # | Decisão | Motivo |
|---|---|---|
| 1 | **Nome QuietDeck mantido** | Em 2026-10-31 a busca no GitHub só achou `junaid-devv/quietdeck-tv-launcher` (0 estrelas, launcher de Android TV, outro domínio). `brew search` e a API de formulae não têm `quietdeck` (404). |
| 2 | **Convenções do Quietbar: `Package.swift` único com targets em `Packages/`, `project.yml`, `make`, scripts de release, DECISIONS.md, commits em português, MIT** | Pedido da especificação. A versão só existe em `project.yml`. |
| 3 | **README em inglês, sem versão em português** | A especificação pede inglês; o Quietbar tem as duas. |
| 4 | **Cask, não fórmula** | O tap só tem `Casks/`, e app com .dmg é cask. A especificação diz "fórmula" no sentido geral. |
| 5 | **Sem Sparkle na 0.1.0** | Não foi pedido, exigiria chave EdDSA e GitHub Pages. O app não acessa a internet sem uma ação do usuário, fora a checagem de updates do Flathub, feita no Deck. Atualiza por `brew upgrade`. |
| 6 | **DeckKit e DeckRemote sem AppKit** | Runners macOS do GitHub não têm Docker, e os testes de integração rodam no Linux com o mesmo código. Hash usa `/usr/bin/shasum` em vez de CryptoKit pelo mesmo motivo, e porque lê ISOs em streaming. |
| 7 | **Sem App Sandbox** | O app executa `/usr/bin/ssh`, `rsync` e `chdman` e grava em `~/.ssh`, o que o sandbox impede. |
| 8 | **Harness em Arch ARM no Mac** | `archlinux:latest` só existe em amd64, e o sshd morre em amd64 emulado: `prctl(PR_SET_SECCOMP)` retorna EINVAL no Rosetta. O CI usa `archlinux:latest` nativo. |
| 9 | **Master SSH sobe separado, com stdio em /dev/null e `-E log`** | Um master criado com `ControlMaster=auto` herda o stderr do processo e nenhum comando veria EOF. Os demais usam `ControlMaster=no`: se o master cair, o comando conecta sozinho. `ControlPath` em `~/.ssh/qd-%C` cabe nos 104 bytes do socket. |
| 10 | **`StrictHostKeyChecking=accept-new` com `known_hosts` próprio** | Confia no primeiro contato, recusa troca de chave depois. Reinstalar o SteamOS exige apagar a linha em `~/Library/Application Support/QuietDeck/known_hosts`. |
| 11 | **Exceção à regra de `/home/deck`: microSD** | A especificação pede escolha interno/microSD, e o cartão fica em `/run/media`. Nada toca no rootfs. |
| 12 | **Exceção à regra de `/home/deck`: instalador oficial do Decky** | `install_release.sh` grava `/etc/systemd/system/plugin_loader.service`. As duas regras da especificação colidem; prevalece a mais específica. `/etc` é um overlay, o rootfs segue read-only, e a UI avisa antes de rodar. O QuietDeck em si não escreve fora de `/home/deck` e do microSD. |
| 13 | **Exceção à regra de `/home/deck`: `systemctl --user mask --runtime`** | Grava um link em `$XDG_RUNTIME_DIR` (tmpfs) por alguns segundos. Ver #14. |
| 14 | **Gravar `shortcuts.vdf` no Game Mode: máscara em runtime, stop, gravação, unmask, start** | `gamescope-session.target` tem `Upholds=steam-launcher.service`, que relança sem atraso, então parar o Steam não abre janela para escrever. `systemctl --user restart gamescope-session.service` é recusado (`RefuseManualStart=yes`). A máscara em `/run` some num reboot: um app que cair no meio não deixa o Deck sem Steam. O arquivo é relido **depois** do Steam morrer, porque ele regrava ao sair. Sem atalho novo, o Steam não é tocado. Fonte: pacotes `gamescope` e `jupiter-hw-support` do repositório da Valve. |
| 15 | **QEMU só cobre fases 1 e 2** | Game Mode não roda em VM (Igalia, post sobre SteamOS em QEMU). A imagem de recovery é modificada offline na partição `var`: sshd habilitado e `shadow` com senha, em `/etc` por overlay. |
| 16 | **DuckStation fica no catálogo como indisponível; PS1 usa SwanStation no RetroArch** | Foi removido do Flathub (fim de vida). `/api/v2/appstream/<id>` responde 200 para apps EOL; a presença real se confere na lista e em `/api/v2/eol/message/<id>`. Pelo mesmo motivo: Ryujinx vira Ryubing, Lime3DS e Citra viram Azahar. Vita3K, Xenia e ES-DE não estão no Flathub. |
| 17 | **Cemu sem configuração de caminhos** | O caminho do config no Flatpak não está documentado, e gravar no lugar errado seria pior que não gravar. A UI explica. |
| 18 | **Cores do RetroArch são baixados do buildbot** | São software do emulador, não ROM nem BIOS. Sem core, o atalho não abre. Só x86_64 e só o que faltar. |
| 19 | **BIOS por hash, não por nome** | `dat/System.dat` do libretro-database (commit em `bios.json`) tem md5 e sha1, sem sha256. PS2 aparece como `ps2-<versão>`, sem scph; `scph39001.bin` casa pelo hash. `dc/flash.bin` vira `dc/dc_flash.bin` no destino. Sem Xbox: o dat não cobre, e o xemu aponta para arquivos do usuário. |
| 20 | **`bios/` plano para os arquivos, `bios/<sistema>` também criado** | A especificação pede `bios/<sistema>`, mas RetroArch e EmuDeck procuram em `bios/` plano. As pastas por sistema existem, os arquivos vão onde os emuladores leem. Com EmuDeck, nem são criadas. |
| 21 | **EmuDeck manda quando existe** | `settings.sh` é lido linha a linha, nunca executado. Com ele, o seletor de microSD fica desligado e nenhum config é gravado. |
| 22 | **Instalação de plugin direto em `~/homebrew/plugins`** | A API local do loader (porta 1337) exige sessão do Steam. O script reproduz `_install` e `set_plugin_dir_permissions` de `backend/decky_loader/browser.py`: sha256, `remote_binary`, dono e permissões. Remover usa `sudo` porque a pasta é do root. O contador de instalações da loja não é incrementado. |
| 23 | **Endpoint da loja: `https://plugins.deckbrew.xyz/plugins`** | `frontend/src/store.tsx:63` e `backend/decky_loader/browser.py:219`. Sem `artifact`, o zip vem de `cdn.tzatzikiweeb.moe/.../versions/<hash>.zip` (`store.tsx:174`). A resposta tem caracteres de controle crus e passa por uma limpeza antes do JSON. |
| 24 | **Compat tools em `~/.local/share/Steam/compatibilitytools.d`** | `~/.steam/root` é symlink para esse caminho. Assets do GE-Proton agora têm `-x86_64` no nome. Download e checksum sha512 acontecem no Deck. Luxtorpeda (arquivado) e Boxtron (parado) ficaram de fora. |
| 25 | **rsync com `--partial-dir`, sem `-a`** | Testado com o openrsync do macOS contra rsync 3: retoma, sha256 confere, e não sobra arquivo pela metade com o nome final. `-a` tentaria preservar dono e grupo. `--protect-args`, `--info=progress2`, `--mkpath` e `--append-verify` são recusados pelo openrsync. |
| 26 | **Aspas no caminho remoto conforme o protocolo do cliente** | O openrsync (protocolo 29) entrega o caminho ao shell remoto: `/home/deck/my sd/` criou a pasta `my` sem erro nenhum. Protocolo ≥ 31 protege sozinho, e aspas viram parte do nome. |
| 27 | **sftp só como fallback, quando faltam flag ou rsync** | `reput` exige o arquivo remoto: o fallback cria com `touch` antes. No modo batch não há percentual. Erro de disco ou rede não cai para sftp. |
| 28 | **Deduplicação por índice no Deck, conferido por `stat`** | `~/.local/share/quietdeck/rom-index.tsv` mapeia o hash da **origem** para o arquivo final, porque um CHD não tem o hash do ISO. Arquivo apagado à mão no Deck reenvia. |
| 29 | **`.m3u` recalculado da pasta real** | Discos podem chegar em trabalhos diferentes; olhar a pasta dá o mesmo resultado em qualquer ordem. Só conjuntos com 2+ discos ganham playlist. |
| 30 | **PS2 `.iso` acima de 900 MB vira `createdvd`; PSP e GameCube não viram CHD** | PPSSPP e Dolphin não entram na lista de CHD do catálogo. `.bin` solto não converte, porque precisa do `.cue`. |
| 31 | **Cabeçalho antes da extensão, pasta antes de tudo** | Pasta de origem é a intenção do usuário. `.iso`, `.bin` e `.chd` servem a muitos sistemas: sem pasta nem cabeçalho, a UI pergunta em vez de chutar. |
| 32 | **chdman e 7zz pelo Homebrew, sob demanda** | Fórmulas `rom-tools` e `sevenzip`. Sem Homebrew, o erro diz o que instalar. Originais nunca são alterados; a pasta de trabalho some depois do envio confirmado. |
| 33 | **`Shortcut.appID` novo usa CRC-32 de `"exe"nome` com bit alto, como o Steam ROM Manager; existentes são lidos do arquivo** | Entradas criadas pelo próprio Steam não seguem o CRC. Chaves do VDF são comparadas sem caixa porque `AppName`/`appname` variam. `Shortcut` usa `/usr/bin/flatpak run` e `FlatpakAppID` vazio. |
| 34 | **Trabalho interrompido não recomeça sozinho** | Pode haver um jogo aberto. Vira `interrupted`, com botão de tentar de novo. O que estava só na fila continua quando o Deck responde. |
| 35 | **Interface só em inglês** | Duplicar todos os textos em `.xcstrings` não paga na 0.1.0. Comentários e documentos internos seguem em português, como no Quietbar. |
| 36 | **`MenuBarExtra`, não `NSStatusItem`** | O Quietbar troca por causa do vidro no painel 3D; aqui o painel é simples e só de leitura. |
| 37 | **Link do Buy Me a Coffee: `buymeacoffee.com/raphaeltorquato`** | O Quietbar não tem esse link, apesar de a especificação citar. A página existe e tem o nome do autor, com o texto padrão do site; não há como confirmar a posse por fora. Confira antes de divulgar. |
| 38 | **Fixtures dizem de onde vieram (`source`)** | `steamos-real`, `container` ou `sintética`. As screenshots usam a sintética: formatos conferidos na imagem 3.9.4, valores inventados. |
| 39 | **Commits por fase cobrem o núcleo; a UI veio depois em commits próprios** | As fases foram desenvolvidas com a fila e a UI por cima. Cada commit de fase compila e passa nos testes em checkout limpo. Os testes de integração entraram em commit único, depois da fase 5. |

## Fontes

Conferidas em 2026-10-31.

- **Decky:** `SteamDeckHomebrew/decky-loader` @ffd103b e `decky-installer`.
- **VDF e artes:** `SteamGridDB/steam-rom-manager` @f68289a, `ValvePython/vdf` @d762926, `sonic2kk/steamtinkerlaunch` @8550ab2, `PhilipK/steam_shortcuts_util` @188d76c.
- **SteamOS:** imagem `steamdeck/20261021.100` (3.9.4) em `steamdeck-images.steamos.cloud`, montada só para leitura, e pacotes em `steamdeck-packages.steamos.cloud`.
- **EmuDeck:** `dragoonDorise/EmuDeck` @dddb302.
- **Extensões:** ES-DE `resources/systems/linux/es_systems.xml` @ef267ae.
- **BIOS:** `libretro/libretro-database` @2c93952.
- **SteamGridDB:** `SteamGridDB/node-steamgriddb` @95c5993.
- **Flathub:** `https://flathub.org/api/v2/appstream` e `/eol/message/<id>`.
- **QEMU:** blogs.igalia.com/berto, "Running the Steam Deck's OS in a virtual machine using QEMU".
