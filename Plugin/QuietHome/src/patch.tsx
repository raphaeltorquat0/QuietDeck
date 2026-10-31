import { Component, createElement, ReactElement, ReactNode } from 'react'
import { QuietHome } from './QuietHome'
import { loadTabs } from './steam'

interface GuardProps {
  original: ReactElement
  children: ReactNode
}

/** Erro de renderização não pode virar a tela de erro do Decky no lugar da home. */
export class Guard extends Component<GuardProps, { failed: boolean }> {
  state = { failed: false }

  static getDerivedStateFromError() {
    return { failed: true }
  }

  componentDidCatch(error: Error, info: { componentStack?: string }) {
    ;(window as any).__quietHomeError = `${error?.stack ?? error}\n${info?.componentStack ?? ''}`
    console.error('Quiet Home:', error)
  }

  render() {
    return this.state.failed ? this.props.original : this.props.children
  }
}

function Home({ original }: { original: ReactElement }) {
  const tabs = loadTabs()
  if (!tabs || !tabs.some((t) => t.games.length > 0)) return original
  return <Guard original={original}><QuietHome tabs={tabs} /></Guard>
}

/** Mantém o elemento que o Decky entrega como está e só troca o conteúdo da rota. */
export function homePatch(props: { path?: string; children: any }) {
  const original = props.children
  props.children = { ...original, type: Home, props: { original: createElement(original.type, original.props) } }
  return props
}
