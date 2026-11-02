"""Desempenho do QuietTune: TDP e clock de GPU por sysfs, só nos limites de fábrica.
Sem overclock e sem voltagem: `apply` só escreve `power*_cap`, o nível e as linhas `s 0`, `s 1` e `c`.
Roda como root pelo Decky. O app chama `uninstall` direto, porque apagar a pasta não dispara `_uninstall`."""
import glob
import json
import logging
import os
import re
import sys

log = logging.getLogger("QuietTune")

# /usr/share/steamos-manager/devices/steam-deck.toml no SteamOS 3.9.5: LCD e OLED têm a mesma faixa.
LIMITS = {
    "Jupiter": {"label": "LCD", "tdp_min": 3, "tdp_max": 15, "gpu_min": 200, "gpu_max": 1600},
    "Galileo": {"label": "OLED", "tdp_min": 3, "tdp_max": 15, "gpu_min": 200, "gpu_max": 1600},
}


class PerformanceError(Exception):
    pass


def _read(path):
    with open(path) as f:
        return f.read().strip()


def _write(path, value):
    try:
        with open(path, "w") as f:
            f.write(f"{value}\n")
    except OSError as error:
        raise PerformanceError(f"{path}: {error}") from error


def _one(root, pattern):
    found = sorted(glob.glob(os.path.join(root, pattern)))
    if not found:
        raise PerformanceError(f"não achei {pattern}")
    return found


def _device(root):
    return _one(root, "sys/class/drm/card?/device/pp_od_clk_voltage")[0].rsplit("/", 1)[0]


def _caps(root):
    return [c for name in ("power1_cap", "power2_cap") for c in _one(root, f"sys/class/drm/card?/device/hwmon/hwmon*/{name}")[:1]]


def model(root="/"):
    """Só aparelhos da Valve conhecidos. Qualquer outro fica sem escrita nenhuma."""
    try:
        vendor = _read(os.path.join(root, "sys/class/dmi/id/sys_vendor"))
        board = _read(os.path.join(root, "sys/class/dmi/id/board_name"))
    except OSError:
        return None
    return board if vendor == "Valve" and board in LIMITS else None


def default_profile(limits):
    return {"tdp": limits["tdp_max"], "gpu": "auto"}


def _whole(value, low, high, name):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{name} fora da faixa {low} a {high}: {value!r}")
    return value


def validate(profile, limits):
    if not isinstance(profile, dict) or profile.get("gpu") not in ("auto", "manual"):
        raise ValueError(f"perfil inválido: {profile!r}")
    keys = {"tdp", "gpu", "gpu_min", "gpu_max"} if profile["gpu"] == "manual" else {"tdp", "gpu"}
    if set(profile) != keys:
        raise ValueError(f"perfil inválido: {profile!r}")
    _whole(profile["tdp"], limits["tdp_min"], limits["tdp_max"], "TDP")
    if profile["gpu"] == "manual":
        low = _whole(profile["gpu_min"], limits["gpu_min"], limits["gpu_max"], "clock mínimo")
        high = _whole(profile["gpu_max"], limits["gpu_min"], limits["gpu_max"], "clock máximo")
        if low > high:
            raise ValueError(f"clock mínimo acima do máximo: {low} > {high}")
    return profile


def read_state(root="/"):
    device = _device(root)
    od = re.findall(r"^[01]:\s+(\d+)Mhz", _read(f"{device}/pp_od_clk_voltage").split("OD_RANGE")[0], re.M)
    return {
        "tdp": int(_read(_caps(root)[0])) // 1_000_000,
        "gpu": _read(f"{device}/power_dpm_force_performance_level"),
        "gpu_min": int(od[0]) if len(od) == 2 else None,
        "gpu_max": int(od[1]) if len(od) == 2 else None,
    }


def matches(state, profile):
    if state["tdp"] != profile["tdp"] or state["gpu"] != profile["gpu"]:
        return False
    return profile["gpu"] == "auto" or (state["gpu_min"], state["gpu_max"]) == (profile["gpu_min"], profile["gpu_max"])


def _set_clocks(device, low, high):
    _write(f"{device}/power_dpm_force_performance_level", "manual")
    _write(f"{device}/pp_od_clk_voltage", f"s 0 {low}")
    _write(f"{device}/pp_od_clk_voltage", f"s 1 {high}")
    _write(f"{device}/pp_od_clk_voltage", "c")


def apply(profile, root="/"):
    """Valida antes de tocar em qualquer arquivo e confere o resultado lendo o sysfs."""
    board = model(root)
    if board is None:
        raise PerformanceError("aparelho sem suporte")
    limits = LIMITS[board]
    validate(profile, limits)
    device = _device(root)
    for cap in _caps(root):
        _write(cap, profile["tdp"] * 1_000_000)
    if profile["gpu"] == "manual":
        _set_clocks(device, profile["gpu_min"], profile["gpu_max"])
    else:
        _set_clocks(device, limits["gpu_min"], limits["gpu_max"])
        _write(f"{device}/power_dpm_force_performance_level", "auto")
    state = read_state(root)
    if not matches(state, profile):
        raise PerformanceError(f"o sysfs não aceitou o perfil: {state}")


def restore(root="/"):
    board = model(root)
    if board is None:
        raise PerformanceError("aparelho sem suporte")
    apply(default_profile(LIMITS[board]), root)


def load_profile(settings):
    with open(settings) as f:
        return json.load(f)


def save_profile(settings, profile):
    os.makedirs(os.path.dirname(settings), exist_ok=True)
    temporary = settings + ".tmp"
    with open(temporary, "w") as f:
        json.dump(profile, f)
    os.replace(temporary, settings)


def forget_profile(settings):
    try:
        os.remove(settings)
    except FileNotFoundError:
        pass


def set_profile(settings, profile, root="/"):
    """Falha no meio volta ao padrão: um Deck com metade do perfil seria pior que nenhum."""
    try:
        apply(profile, root)
    except PerformanceError:
        restore(root)
        forget_profile(settings)
        raise
    save_profile(settings, profile)


def reset(settings, root="/"):
    restore(root)
    forget_profile(settings)


def boot(settings, root="/"):
    """O arquivo só existe enquanto há perfil ativo. Sem ele, o que o Steam fez não é da nossa conta."""
    if not os.path.exists(settings):
        return "none"
    board = model(root)
    if board is None:
        log.warning("perfil ignorado: aparelho sem suporte")
        return "unsupported"
    try:
        apply(validate(load_profile(settings), LIMITS[board]), root)
        return "applied"
    except (OSError, ValueError, PerformanceError) as error:
        log.error("perfil inválido, voltando ao padrão: %s", error)
        reset(settings, root)
        return "restored"


def reapply(settings, root="/"):
    """Steam e steamos-manager escrevem nos mesmos arquivos quando um jogo abre."""
    if not os.path.exists(settings):
        return False
    board = model(root)
    if board is None:
        return False
    # Mesma régua do boot: um arquivo corrompido não pode virar exceção a cada jogo aberto.
    try:
        profile = validate(load_profile(settings), LIMITS[board])
    except (OSError, ValueError) as error:
        log.error("perfil inválido, voltando ao padrão: %s", error)
        reset(settings, root)
        return False
    state = read_state(root)
    if matches(state, profile):
        return False
    log.info("perfil sobrescrito (%s), reaplicando", state)
    apply(profile, root)
    return True


def uninstall(settings, root="/"):
    if not os.path.exists(settings):
        return
    if model(root) is not None:
        restore(root)
    forget_profile(settings)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    if len(sys.argv) != 3 or sys.argv[1] != "uninstall":
        sys.exit("uso: performance.py uninstall <settings>")
    uninstall(sys.argv[2])
