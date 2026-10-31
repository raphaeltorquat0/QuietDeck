#!/usr/bin/env python3
"""Gera a tabela de BIOS (só hashes, nunca arquivos) a partir de dat/System.dat do libretro-database.
Uso: scripts/gen-bios-table.py <System.dat> <commit>   Saída: Packages/DeckKit/Sources/DeckKit/Resources/bios.json
"""
import json, re, sys

ROM = re.compile(r'rom \( name (?:"([^"]+)"|(\S+)) size (\d+) crc \S+ md5 (\S+) sha1 (\S+) \)')
# arquivo no dat -> (sistema, destino relativo a bios/, obrigatório para o sistema)
WANTED = {
    "scph5500.bin": ("psx", "scph5500.bin"), "scph5501.bin": ("psx", "scph5501.bin"),
    "scph5502.bin": ("psx", "scph5502.bin"), "scph1001.bin": ("psx", "scph1001.bin"),
    "dc/dc_boot.bin": ("dreamcast", "dc/dc_boot.bin"), "dc/flash.bin": ("dreamcast", "dc/dc_flash.bin"),
    "sega_101.bin": ("saturn", "sega_101.bin"), "mpr-17933.bin": ("saturn", "mpr-17933.bin"),
    "gba_bios.bin": ("gba", "gba_bios.bin"),
    "bios_CD_U.bin": ("segacd", "bios_CD_U.bin"), "bios_CD_E.bin": ("segacd", "bios_CD_E.bin"),
    "bios_CD_J.bin": ("segacd", "bios_CD_J.bin"),
    "bios7.bin": ("nds", "bios7.bin"), "bios9.bin": ("nds", "bios9.bin"), "firmware.bin": ("nds", "firmware.bin"),
}

dat, commit = sys.argv[1], sys.argv[2]
entries = []
for line in open(dat, encoding="utf-8", errors="replace"):
    m = ROM.search(line)
    if not m:
        continue
    name = m.group(1) or m.group(2)
    size, md5, sha1 = int(m.group(3)), m.group(4).lower(), m.group(5).lower()
    if name in WANTED:
        system, dest = WANTED[name]
    elif name.startswith("pcsx2/bios/"):
        # PS2 entra pelo hash: no dat os nomes são ps2-<versão>, não scph (DECISIONS.md #19).
        system, dest = "ps2", name.rsplit("/", 1)[1]
    else:
        continue
    entries.append({"system": system, "file": dest, "size": size, "md5": md5, "sha1": sha1})

missing = set(WANTED) - {e for e in WANTED if any(x["file"] == WANTED[e][1] for x in entries)}
if missing:
    sys.exit(f"faltam no dat: {sorted(missing)}")
entries.sort(key=lambda e: (e["system"], e["file"]))
out = {"source": "libretro-database dat/System.dat", "commit": commit, "entries": entries}
path = "Packages/DeckKit/Sources/DeckKit/Resources/bios.json"
json.dump(out, open(path, "w"), indent=1)
print(path, len(entries))
