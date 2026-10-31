import { definePlugin, routerHook, toaster } from '@decky/api'
import { QuietHome } from './QuietHome'
import { loadTabs } from './steam'

const HOME = '/library/home'

/** A home nativa só é trocada se os dados do cliente responderem; senão ela fica como está. */
export default definePlugin(() => {
  const patch = routerHook.addPatch(HOME, (props: any) => {
    const tabs = loadTabs()
    if (tabs && tabs.some((t) => t.games.length > 0)) {
      props.children = { ...props.children, type: QuietHome, props: { tabs } }
    } else {
      toaster.toast({ title: 'Quiet Home', body: 'Este cliente Steam mudou. A home nativa continua ativa.' })
    }
    return props
  })
  return {
    name: 'Quiet Home',
    icon: <span>Q</span>,
    content: <div style={{ padding: 12 }}>Quiet Home ativo. Desative o plugin para voltar à home nativa.</div>,
    onDismount() {
      routerHook.removePatch(HOME, patch)
    },
  }
})
