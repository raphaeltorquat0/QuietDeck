import { definePlugin, routerHook } from '@decky/api'
import { homePatch } from './patch'

const HOME = '/library/home'

/** A home nativa fica por baixo: qualquer falha da nova volta para ela. Ver `Guard`. */
export default definePlugin(() => {
  const patch = routerHook.addPatch(HOME, homePatch)
  return {
    name: 'Quiet Home',
    icon: <span>Q</span>,
    content: <div style={{ padding: 12 }}>Quiet Home ativo. Desative o plugin para voltar à home nativa.</div>,
    onDismount() {
      routerHook.removePatch(HOME, patch)
    },
  }
})
