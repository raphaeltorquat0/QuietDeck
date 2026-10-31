"""Troca o patch de Quiet Glass no CSS Loader conforme há jogo aberto.
O CSS Loader só atende em localhost, sem CORS, então a chamada sai daqui e não do frontend."""
import asyncio
import json
import os
import urllib.request

try:
    import decky
except ImportError:  # Fora do Deck, para o teste.
    decky = None

CSS_LOADER = "http://127.0.0.1:35821/req"
THEME, PATCH = "Quiet Glass", "Menus"


def desired(running, force):
    return "Vidro" if force or not running else "Opaco"


def post(value):
    body = {"method": "set_patch_of_theme", "args": {"themeName": THEME, "patchName": PATCH, "value": value}}
    request = urllib.request.Request(CSS_LOADER, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response).get("success", False)


class Plugin:
    running = False
    force = False

    def _settings(self):
        return os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "settings.json")

    async def _apply(self):
        try:
            if not await asyncio.to_thread(post, desired(self.running, self.force)):
                decky.logger.warning("CSS Loader recusou a troca do patch")
        except OSError as error:
            # CSS Loader desligado ou reiniciando: o tema fica como está.
            decky.logger.warning("CSS Loader fora do ar: %s", error)

    async def _main(self):
        try:
            with open(self._settings()) as f:
                self.force = json.load(f).get("force", False)
        except (OSError, ValueError):
            self.force = False

    async def _unload(self):
        pass

    async def set_running(self, running):
        self.running = running
        await self._apply()

    async def get_force(self):
        return self.force

    async def set_force(self, force):
        self.force = force
        os.makedirs(decky.DECKY_PLUGIN_SETTINGS_DIR, exist_ok=True)
        with open(self._settings(), "w") as f:
            json.dump({"force": force}, f)
        await self._apply()
