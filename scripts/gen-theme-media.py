#!/usr/bin/env python3
"""Gera os sons e o vídeo de boot do tema. Tudo sintetizado aqui: nenhum arquivo de terceiros.
Volume: RMS igual ao som nativo que cada um substitui (medido no SteamOS 3.9.5)."""
import json, math, os, struct, subprocess, wave

OUT = "Packages/DeckKit/Sources/DeckKit/Resources/theme"
RATE = 44100
# arquivo: (frequências, duração, RMS nativo)
SOUNDS = {
    "deck_ui_navigation.wav": ([880], 0.05, 0.011),            # mover
    "deck_ui_tile_scroll.wav": ([880], 0.05, 0.019),           # mover na linha
    "deck_ui_default_activation.wav": ([660, 990], 0.12, 0.038),  # confirmar
    "deck_ui_out_of_game_detail.wav": ([660, 440], 0.14, 0.020),  # voltar
    "deck_ui_hide_modal.wav": ([660, 440], 0.14, 0.023),          # voltar
}

def tone(freqs, seconds, target):
    n = int(RATE * seconds)
    step = n // len(freqs)
    samples = []
    for i in range(n):
        f = freqs[min(i // step, len(freqs) - 1)]
        env = min(i / 220, 1) * math.exp(-5 * i / n)
        samples.append(math.sin(2 * math.pi * f * i / RATE) * env)
    rms = math.sqrt(sum(s * s for s in samples) / n)
    return [s * target / rms for s in samples]

os.makedirs(f"{OUT}/sounds", exist_ok=True)
for name, (freqs, seconds, target) in SOUNDS.items():
    with wave.open(f"{OUT}/sounds/{name}", "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<hh", int(s * 32767), int(s * 32767)) for s in tone(freqs, seconds, target)))
json.dump({"name": "Quiet", "author": "QuietDeck", "version": "v1.0", "manifest_version": 2, "music": False,
           "description": "Minimal UI sounds", "ignore": [], "mappings": {}}, open(f"{OUT}/sounds/pack.json", "w"), indent=2)

# 20 s: maior que os 17 s de boot medidos no Deck, para não sobrar tela preta depois do vídeo.
subprocess.run(["swift", "scripts/quiet-logo.swift", "/tmp/quiet-logo.png"], check=True)
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=1280x800:r=24:d=20", "-loop", "1", "-i", "/tmp/quiet-logo.png",
                "-filter_complex", "[1]format=rgba,fade=in:st=0:d=1.5:alpha=1[l];[0][l]overlay=shortest=1",
                "-c:v", "libvpx-vp9", "-crf", "40", "-b:v", "0", "-pix_fmt", "yuv420p", f"{OUT}/boot.webm"], check=True)
print(sorted(os.listdir(f"{OUT}/sounds")), os.path.getsize(f"{OUT}/boot.webm"))
