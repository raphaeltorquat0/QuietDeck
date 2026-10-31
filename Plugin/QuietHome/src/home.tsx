import { Component, ReactNode } from 'react'
import { QuietHome } from './QuietHome'
import { loadTabs } from './steam'

export const NATIVE_HOME = '/library/home'
export const QUIET_HOME = '/quiet-home'

declare const SteamUIStore: any

const history = () => SteamUIStore?.WindowStore?.GamepadUIMainWindowInstance?.m_history

/** Falhou uma vez, fica na home nativa até o Steam reiniciar. */
let failed = false

const ready = () => !!loadTabs()?.some((t) => t.games.length > 0)

class Guard extends Component<{ children: ReactNode }, { error: boolean }> {
  state = { error: false }

  static getDerivedStateFromError() {
    return { error: true }
  }

  componentDidCatch(error: Error, info: { componentStack?: string }) {
    ;(window as any).__quietHomeError = `${error?.stack ?? error}\n${info?.componentStack ?? ''}`
    failed = true
    history()?.replace(NATIVE_HOME)
  }

  render() {
    return this.state.error ? null : this.props.children
  }
}

export function QuietRoute() {
  const tabs = loadTabs()
  if (!tabs) {
    failed = true
    history()?.replace(NATIVE_HOME)
    return null
  }
  return <Guard><QuietHome tabs={tabs} /></Guard>
}

/** Sem patch na rota nativa: ela segue intacta, e só redirecionamos quando há dados para mostrar. */
export function startRedirect(): () => void {
  let stop = () => {}
  let stopped = false

  const send = () => {
    const h = history()
    if (!failed && h?.location?.pathname === NATIVE_HOME && ready()) h.replace(QUIET_HOME)
  }

  const attach = () => {
    const h = history()
    if (stopped) return
    if (!h?.listen) {
      timer = setTimeout(attach, 500)
      return
    }
    stop = h.listen(send)
    send()
    // No início do Steam as coleções chegam depois da rota.
    poll = setInterval(send, 1000)
    setTimeout(() => clearInterval(poll), 60000)
  }

  let timer: ReturnType<typeof setTimeout> = setTimeout(attach, 0)
  let poll: ReturnType<typeof setInterval>

  return () => {
    stopped = true
    clearTimeout(timer)
    clearInterval(poll)
    stop()
    if (history()?.location?.pathname === QUIET_HOME) history().replace(NATIVE_HOME)
  }
}
