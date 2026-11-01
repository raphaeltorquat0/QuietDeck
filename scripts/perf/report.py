#!/usr/bin/env python3
"""Gera docs/perf/quiet-glass.md a partir da pasta extraída de qd-bench.tgz. Uso: report.py <qd-bench> <saída>
1% low é 1000 / percentil 99 do frametime, calculado sobre cada quadro, sem o resumo do MangoHud."""
import collections
import csv
import glob
import os
import statistics
import sys

ROOT, OUT = sys.argv[1], sys.argv[2]
SKIP = 5  # Segundos descartados no começo: sobra da transição.
DIM = 30000
HOME_DIM = 5000  # A home compara décimos de watt, então só vale o mesmo nível de brilho.
NAMES = {"pesado": "Solasta II (VSync duplo, 22 FPS)", "leve": "ReStory Playtest", "nao-steam": "RetroArch (atalho não-Steam)", "travado30": "Alone in the Dark (extra, travado a 30 FPS)"}
CONDITIONS = {"fechado": "Menu fechado", "menu-opaco": "Menu aberto, opaco", "menu-vidro": "Menu aberto, vidro"}

rows = collections.defaultdict(list)
with open(os.path.join(ROOT, "samples.csv")) as f:
    for row in csv.DictReader(f):
        if row["label"] != "pausa":
            rows[row["label"]].append(row)


def power(label, limit=DIM):
    samples = rows[label][SKIP:]
    # Só tela escurecida: o brilho pesa quase 2 W e o Steam o muda sozinho.
    valid = [s for s in samples if s["status"] == "Discharging" and float(s["watts"]) > 0 and int(s["brightness"]) < limit]
    return {
        "w": statistics.mean(float(s["watts"]) for s in valid) if valid else None,
        "apu": statistics.mean(float(s["apu_watts"]) for s in samples),
        "cpu": statistics.mean(float(s["cpu_c"]) for s in samples),
        "gpu": statistics.mean(float(s["gpu_c"]) for s in samples),
        "fan": statistics.mean(int(s["fan"] or 0) for s in samples),
        "seconds": len(samples),
        "valid": len(valid),
        "light": {s["brightness"] for s in samples},
    }


def frames(label):
    files = [f for f in glob.glob(os.path.join(ROOT, "mango", label, "*.csv")) if not f.endswith("_summary.csv")]
    times = []
    for path in files:
        with open(path) as f:
            lines = f.read().splitlines()
        for line in lines[3:]:
            cells = line.split(",")
            if len(cells) > 1:
                times.append(float(cells[1]))
    # Pula o mesmo trecho de transição, medido em tempo de quadro.
    elapsed, keep = 0.0, []
    for t in times:
        elapsed += t / 1000
        if elapsed > SKIP:
            keep.append(t)
    if not keep:
        return None
    ordered = sorted(keep)
    return {"fps": 1000 * len(keep) / sum(keep), "low": 1000 / ordered[int(len(ordered) * 0.99)], "frames": len(keep)}


def number(value, digits=1):
    return "n/d" if value is None else f"{value:.{digits}f}".replace(".", ",")


def mean(values):
    values = [v for v in values if v is not None]
    return statistics.mean(values) if values else None


lines = ["# Quiet Glass: FPS e consumo", "", "Relatório gerado por `scripts/perf/report.py` com dados do Deck real. Protocolo em `SMOKE_TEST.md`.", ""]
if os.path.exists(os.path.join(ROOT, "notes.md")):
    lines += open(os.path.join(ROOT, "notes.md")).read().splitlines() + [""]

lines += ["## Home parada", "", "| Condição | Bloco | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Ventoinha (rpm) | Amostras válidas |", "|---|---|---:|---:|---:|---:|---:|---:|"]
home = {}
for patch, title in (("vidro", "Vidro"), ("opaco", "Opaco")):
    home[patch] = []
    for rep in (1, 2):
        p = power(f"home/{patch}/{rep}", HOME_DIM)
        home[patch].append(p["w"])
        lines.append(f"| {title} | {rep} | {number(p['w'], 2)} | {number(p['apu'], 2)} | {number(p['cpu'])} | {number(p['gpu'])} | {number(p['fan'], 0)} | {p['valid']}/{p['seconds']} |")
delta = mean(home["vidro"]) - mean(home["opaco"])
apu = mean([power(f"home/vidro/{r}")["apu"] for r in (1, 2)]) - mean([power(f"home/opaco/{r}")["apu"] for r in (1, 2)])
per_block = [v - o for v, o in zip(home["vidro"], home["opaco"])]
verdict = "aprovado" if delta <= 0.3 else "reprovado"
lines += ["", f"**Vidro menos opaco: {number(delta, 2)} W em média** (por bloco: {', '.join(number(d, 2) for d in per_block)} W). Limite: 0,3 W. **Resultado: {verdict}.** Só a APU, que não depende do brilho: {number(apu, 2)} W.", ""]

lines += ["## Jogos", ""]
summary = []
for game, title in NAMES.items():
    # Medição parcial: jogo sem as três condições não entra na tabela.
    if not all(f"{game}/{condition}/1" in rows for condition in CONDITIONS):
        continue
    lines += [f"### {title}", "", "| Condição | Rodada | FPS médio | 1% low | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Quadros |", "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    totals = {}
    for condition, name in CONDITIONS.items():
        fps = []
        for rep in (1, 2):
            label = f"{game}/{condition}/{rep}"
            # O RetroArch não deixa a tela escurecer: vale o bloco todo, e a referência dele é a APU.
            p, f = power(label, 65536 if game == "nao-steam" else DIM), frames(label)
            fps.append(f["fps"] if f else None)
            totals.setdefault(condition, []).append((f, p))
            lines.append(f"| {name} | {rep} | {number(f and f['fps'])} | {number(f and f['low'])} | {number(p['w'], 2)} | {number(p['apu'], 2)} | {number(p['cpu'])} | {number(p['gpu'])} | {f['frames'] if f else 0} |")
    averages = {c: {"fps": mean([f["fps"] for f, _ in v if f]), "low": mean([f["low"] for f, _ in v if f]), "w": mean([p["w"] for _, p in v]), "apu": mean([p["apu"] for _, p in v])} for c, v in totals.items()}
    summary.append((title, averages))
    lines.append("")

lines += ["## Vidro contra opaco com o menu aberto em jogo", "", "| Jogo | FPS opaco | FPS vidro | Diferença | 1% low opaco | 1% low vidro | W opaco | W vidro | Diferença (W) | Diferença na APU (W) |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
for title, a in summary:
    o, v = a["menu-opaco"], a["menu-vidro"]
    change = (v["fps"] - o["fps"]) / o["fps"] * 100 if o["fps"] and v["fps"] else None
    lines.append(f"| {title} | {number(o['fps'])} | {number(v['fps'])} | {number(change)}% | {number(o['low'])} | {number(v['low'])} | {number(o['w'], 2)} | {number(v['w'], 2)} | {number((v['w'] or 0) - (o['w'] or 0), 2)} | {number(v['apu'] - o['apu'], 2)} |")
lines.append("")
if os.path.exists(os.path.join(ROOT, "conclusion.md")):
    lines += open(os.path.join(ROOT, "conclusion.md")).read().splitlines() + [""]

with open(OUT, "w") as f:
    f.write("\n".join(lines))
print("\n".join(lines[:14]))
