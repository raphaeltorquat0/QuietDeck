#!/usr/bin/env python3
"""Roda no Deck, sem root e sem escrever fora de /tmp. Grava uma linha por segundo com a condição atual.
O Deck não tem `power_now`: consumo é corrente vezes tensão da bateria, válido só descarregando."""
import glob
import os
import sys
import time

OUT, LABEL = sys.argv[1], sys.argv[2]
BAT = "/sys/class/power_supply/BAT1/"
HWMON = {os.path.basename(open(p).read().strip()): os.path.dirname(p) for p in glob.glob("/sys/class/hwmon/hwmon*/name")}
GPU = glob.glob("/sys/class/drm/card?/device")[0]
LIGHT = glob.glob("/sys/class/backlight/*/brightness")[0]


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


with open(OUT, "a", buffering=1) as out:
    out.write("time,label,status,capacity,watts,apu_watts,cpu_c,gpu_c,fan,sclk,brightness\n")
    while os.path.exists(LABEL):
        watts = int(read(BAT + "current_now") or 0) * int(read(BAT + "voltage_now") or 0) / 1e12
        sclk = next((x.split()[1] for x in read(GPU + "/pp_dpm_sclk").splitlines() if x.endswith("*")), "")
        out.write(",".join(str(x) for x in (
            round(time.time(), 1), read(LABEL), read(BAT + "status"), read(BAT + "capacity"), round(watts, 3),
            int(read(HWMON["amdgpu"] + "/power1_average") or 0) / 1e6,
            int(read(HWMON["k10temp"] + "/temp1_input") or 0) / 1000, int(read(HWMON["amdgpu"] + "/temp1_input") or 0) / 1000,
            read(HWMON["steamdeck_hwmon"] + "/fan1_input"), sclk, read(LIGHT),
        )) + "\n")
        time.sleep(1)
