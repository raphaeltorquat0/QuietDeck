"""Backend do QuietTune: só desempenho, exposto pelas chamadas do Decky. O tema fica no frontend (src/theme.ts).
Sem socket, porta ou servidor de rede."""
import os

import decky
import performance


class Plugin:
    def _settings(self):
        return os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "performance.json")

    def _run(self, action):
        """Toda falha volta para a interface e fica no log do plugin."""
        try:
            return {"ok": True, "value": action()}
        except (OSError, ValueError, performance.PerformanceError) as error:
            decky.logger.error("desempenho: %s", error)
            return {"ok": False, "error": str(error)}

    async def _main(self):
        performance.log.handlers = decky.logger.handlers
        result = self._run(lambda: performance.boot(self._settings()))
        decky.logger.info("perfil no início: %s", result)

    async def _unload(self):
        pass

    async def _uninstall(self):
        self._run(lambda: performance.uninstall(self._settings()))

    async def get_state(self):
        def state():
            board = performance.model()
            if board is None:
                return {"supported": False}
            return {
                "supported": True,
                "limits": performance.LIMITS[board],
                "state": performance.read_state(),
                "charge_limit": performance.read_charge_limit(),
                "custom": os.path.exists(self._settings()),
            }

        return self._run(state)

    async def set_profile(self, profile):
        return self._run(lambda: performance.set_profile(self._settings(), profile))

    async def set_charge_limit(self, level):
        return self._run(lambda: performance.set_charge_limit(level))

    async def reapply(self):
        return self._run(lambda: performance.reapply(self._settings()))

    async def restore_defaults(self):
        return self._run(lambda: performance.reset(self._settings()))
