"""Roda com `python3 -I Plugin/QuietTune/tests/test_performance.py`. O sysfs é uma árvore falsa em disco."""
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "py_modules"))
import performance as p

OD = "OD_SCLK:\n0:       {}Mhz\n1:       {}Mhz\nOD_RANGE:\nSCLK:     200Mhz       1600Mhz\nCCLK:    1400Mhz       3500Mhz\n"


class FakeDeck:
    """`pp_od_clk_voltage` é regravado por `sync`, como o kernel faria ao receber `c`."""

    def __init__(self, board="Jupiter", vendor="Valve", level="manual", low=1600, high=1600, tdp=15):
        self.root = tempfile.mkdtemp()
        self.settings = os.path.join(self.root, "settings", "performance.json")
        self.device = os.path.join(self.root, "sys/class/drm/card0/device")
        self.hwmon = os.path.join(self.device, "hwmon/hwmon6")
        os.makedirs(self.hwmon)
        os.makedirs(os.path.join(self.root, "sys/class/dmi/id"))
        self.put("sys/class/dmi/id/board_name", board)
        self.put("sys/class/dmi/id/sys_vendor", vendor)
        self.put("sys/class/drm/card0/device/power_dpm_force_performance_level", level)
        self.put("sys/class/drm/card0/device/pp_od_clk_voltage", OD.format(low, high))
        for cap in ("power1_cap", "power2_cap"):
            self.put(f"sys/class/drm/card0/device/hwmon/hwmon6/{cap}", tdp * 1_000_000)
        os.makedirs(os.path.join(self.root, "sys/class/hwmon/hwmon3"))
        self.put("sys/class/hwmon/hwmon3/name", "steamdeck_hwmon")
        self.put("sys/class/hwmon/hwmon3/max_battery_charge_level", 0)

    def put(self, relative, value):
        with open(os.path.join(self.root, relative), "w") as f:
            f.write(f"{value}\n")

    def get(self, relative):
        with open(os.path.join(self.root, relative)) as f:
            return f.read().strip()

    def writes(self):
        return {name: self.get(f"sys/class/drm/card0/device/{name}") for name in ("power_dpm_force_performance_level", "pp_od_clk_voltage", "hwmon/hwmon6/power1_cap", "hwmon/hwmon6/power2_cap")}

    def close(self):
        shutil.rmtree(self.root)


def kernel(deck):
    """Substitui `_write` para aplicar `s`/`c` como o amdgpu e registrar cada escrita."""
    state = {"low": 1600, "high": 1600}
    log = []
    original = p._write

    def write(path, value):
        log.append((os.path.basename(path), str(value)))
        if path.endswith("pp_od_clk_voltage"):
            text = str(value)
            if text.startswith("s 0"):
                state["low"] = int(text.split()[2])
            elif text.startswith("s 1"):
                state["high"] = int(text.split()[2])
            elif text == "c":
                original(path, OD.format(state["low"], state["high"]))
            else:
                raise AssertionError(f"escrita proibida: {text}")
        else:
            original(path, value)

    p._write = write
    return log


GOOD = {"tdp": 8, "gpu": "manual", "gpu_min": 800, "gpu_max": 1200}


def rejected(profile, limits=p.LIMITS["Jupiter"]):
    try:
        p.validate(profile, limits)
    except ValueError:
        return True
    return False


def test_model_detection():
    for board, expected in (("Jupiter", "Jupiter"), ("Galileo", "Galileo"), ("Aerith", None)):
        deck = FakeDeck(board=board)
        assert p.model(deck.root) == expected
        deck.close()
    deck = FakeDeck(vendor="ASUSTeK")
    assert p.model(deck.root) is None
    deck.close()


def test_rejects_everything_outside_factory_limits():
    for bad in (
        {"tdp": 2, "gpu": "auto"}, {"tdp": 16, "gpu": "auto"}, {"tdp": 8.5, "gpu": "auto"}, {"tdp": "8", "gpu": "auto"}, {"tdp": True, "gpu": "auto"},
        {"tdp": 8, "gpu": "manual", "gpu_min": 199, "gpu_max": 1600}, {"tdp": 8, "gpu": "manual", "gpu_min": 200, "gpu_max": 1601},
        {"tdp": 8, "gpu": "manual", "gpu_min": 900, "gpu_max": 800}, {"tdp": 8, "gpu": "manual", "gpu_min": 800},
        {"tdp": 8, "gpu": "auto", "voltage": 1000}, {"tdp": 8, "gpu": "auto", "gpu_max": 1600},
        {"tdp": 8, "gpu": "profile_peak"}, {"tdp": 8}, None, [],
    ):
        assert rejected(bad), bad
    assert not rejected(GOOD) and not rejected({"tdp": 3, "gpu": "auto"}) and not rejected({"tdp": 15, "gpu": "auto"})


def test_rejected_profile_writes_nothing():
    deck = FakeDeck()
    before = deck.writes()
    try:
        p.apply({"tdp": 29, "gpu": "auto"}, deck.root)
        assert False
    except ValueError:
        pass
    assert deck.writes() == before
    deck.close()


def test_unsupported_device_never_writes():
    deck = FakeDeck(board="Aerith")
    before = deck.writes()
    for action in (lambda: p.apply(GOOD, deck.root), lambda: p.restore(deck.root)):
        try:
            action()
            assert False
        except p.PerformanceError:
            pass
    assert deck.writes() == before
    deck.close()


def test_apply_writes_only_expected_files_and_reads_back():
    deck = FakeDeck()
    original = p._write
    log = kernel(deck)
    try:
        p.apply(GOOD, deck.root)
    finally:
        p._write = original
    assert p.read_state(deck.root) == {"tdp": 8, "gpu": "manual", "gpu_min": 800, "gpu_max": 1200}
    assert deck.get("sys/class/drm/card0/device/hwmon/hwmon6/power2_cap") == "8000000"
    assert {name for name, _ in log} == {"power1_cap", "power2_cap", "power_dpm_force_performance_level", "pp_od_clk_voltage"}
    assert [v for n, v in log if n == "pp_od_clk_voltage"] == ["s 0 800", "s 1 1200", "c"]
    deck.close()


def test_restore_returns_factory_defaults():
    deck = FakeDeck(tdp=6)
    original = p._write
    kernel(deck)
    try:
        p.restore(deck.root)
    finally:
        p._write = original
    state = p.read_state(deck.root)
    assert (state["tdp"], state["gpu"], state["gpu_min"], state["gpu_max"]) == (15, "auto", 200, 1600)
    deck.close()


def test_kernel_refusal_is_reported_and_restores():
    deck = FakeDeck()
    original = p._write

    def refuse(path, value):
        if str(value) == "s 0 800":
            raise p.PerformanceError("recusado")
        original(path, value)

    p._write = refuse
    p_restore = p.restore
    calls = []
    p.restore = lambda root="/": calls.append(root)
    try:
        p.set_profile(deck.settings, GOOD, deck.root)
        assert False
    except p.PerformanceError:
        pass
    finally:
        p._write = original
        p.restore = p_restore
    assert calls == [deck.root] and not os.path.exists(deck.settings)
    deck.close()


def with_kernel(deck, action):
    original = p._write
    kernel(deck)
    try:
        return action()
    finally:
        p._write = original


def test_boot_cases():
    deck = FakeDeck()
    assert p.boot(deck.settings, deck.root) == "none"
    assert p.read_state(deck.root)["gpu"] == "manual"  # Sem perfil, o estado do Steam fica.
    p.save_profile(deck.settings, GOOD)
    assert with_kernel(deck, lambda: p.boot(deck.settings, deck.root)) == "applied"
    assert p.read_state(deck.root)["tdp"] == 8
    for broken in ('{"tdp": 99, "gpu": "auto"}', "não é json", '{"tdp": 8}'):
        with open(deck.settings, "w") as f:
            f.write(broken)
        assert with_kernel(deck, lambda: p.boot(deck.settings, deck.root)) == "restored", broken
        assert not os.path.exists(deck.settings) and p.read_state(deck.root)["gpu"] == "auto"
    deck.close()


def test_reapply_only_when_overwritten():
    deck = FakeDeck()
    assert p.reapply(deck.settings, deck.root) is False
    with_kernel(deck, lambda: p.set_profile(deck.settings, GOOD, deck.root))
    assert with_kernel(deck, lambda: p.reapply(deck.settings, deck.root)) is False
    deck.put("sys/class/drm/card0/device/hwmon/hwmon6/power1_cap", 15_000_000)
    assert with_kernel(deck, lambda: p.reapply(deck.settings, deck.root)) is True
    assert p.read_state(deck.root)["tdp"] == 8
    deck.close()


def test_reapply_resets_broken_profile():
    deck = FakeDeck()
    os.makedirs(os.path.dirname(deck.settings), exist_ok=True)
    with open(deck.settings, "w") as f:
        f.write('{"tdp": 99, "gpu": "auto"}')
    assert with_kernel(deck, lambda: p.reapply(deck.settings, deck.root)) is False
    assert not os.path.exists(deck.settings) and p.read_state(deck.root)["gpu"] == "auto"
    deck.close()


def test_charge_limit_writes_one_file_within_range():
    deck = FakeDeck()
    limit = "sys/class/hwmon/hwmon3/max_battery_charge_level"
    before = deck.writes()
    assert p.set_charge_limit(50, deck.root) == 50 and deck.get(limit) == "50"
    assert p.set_charge_limit(0, deck.root) == 0 and deck.get(limit) == "0"
    for bad in (10, 101, -1, "50", 50.0, True, None):
        try:
            p.set_charge_limit(bad, deck.root)
            assert False, bad
        except ValueError:
            pass
    assert deck.get(limit) == "0" and deck.writes() == before
    # O sysfs que não muda o valor é falha, não sucesso silencioso.
    original = p._write
    p._write = lambda path, value: None
    try:
        p.set_charge_limit(80, deck.root)
        assert False
    except p.PerformanceError:
        pass
    finally:
        p._write = original
    # Desinstalar tira o limite mesmo sem perfil de TDP gravado.
    p.set_charge_limit(50, deck.root)
    p.uninstall(deck.settings, deck.root)
    assert deck.get(limit) == "0"
    deck.close()
    other = FakeDeck(vendor="Acme")
    try:
        p.set_charge_limit(50, other.root)
        assert False
    except p.PerformanceError:
        pass
    assert other.get(limit) == "0"
    other.close()


def test_uninstall_restores_only_if_we_changed_something():
    deck = FakeDeck(level="manual", low=1600, high=1600)
    before = deck.writes()
    p.uninstall(deck.settings, deck.root)
    assert deck.writes() == before
    with_kernel(deck, lambda: p.set_profile(deck.settings, GOOD, deck.root))
    with_kernel(deck, lambda: p.uninstall(deck.settings, deck.root))
    assert p.read_state(deck.root)["gpu"] == "auto" and not os.path.exists(deck.settings)
    deck.close()


for name, test in sorted(globals().copy().items()):
    if name.startswith("test_"):
        test()
print("performance ok")
