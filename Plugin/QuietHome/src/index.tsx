import { definePlugin, routerHook } from '@decky/api'
import { QUIET_HOME, QuietRoute, startRedirect } from './home'

export default definePlugin(() => {
  routerHook.addRoute(QUIET_HOME, QuietRoute, { exact: true })
  const stop = startRedirect()
  return {
    name: 'Quiet Home',
    icon: <span>Q</span>,
    content: <div style={{ padding: 12 }}>Quiet Home ativo. Desative o plugin para voltar à home nativa.</div>,
    onDismount() {
      stop()
      routerHook.removeRoute(QUIET_HOME)
    },
  }
})
