import { Focusable, GamepadButton, Navigation } from '@decky/ui'
import { useEffect, useMemo, useRef, useState } from 'react'
import { achievements, downloadPercent, Game, loadTabs, openStore, play, playedLine, requestDetails, Tab } from './steam'

const styles = `
.qh { position: absolute; inset: 0; background: #0b0d10; color: #fff; overflow: hidden; display: flex; flex-direction: column; }
.qh-art { position: absolute; inset: 0; background-size: cover; background-position: center; }
.qh-scrim { position: absolute; inset: 0; background: linear-gradient(to right, rgba(0,0,0,.86) 0%, rgba(0,0,0,.55) 55%, rgba(0,0,0,.3) 100%), linear-gradient(to top, rgba(0,0,0,.92) 0%, rgba(0,0,0,.45) 55%, rgba(0,0,0,.45) 100%); }
.qh-body { position: relative; flex: 1; display: flex; flex-direction: column; padding: 56px 28px 44px; min-height: 0; }
.qh-info { flex: 1; min-height: 0; }
.qh-title { font-size: 30px; font-weight: 600; line-height: 1.15; margin-bottom: 6px; text-shadow: 0 1px 4px rgba(0,0,0,.6); }
.qh-meta { font-size: 16px; font-weight: 500; line-height: 1.35; }
.qh-play { display: inline-flex; margin-top: 12px; background: #fff; color: #0b0d10; border-radius: 8px; padding: 7px 20px; font-size: 16px; font-weight: 600; }
.qh-play.gpfocus { outline: 3px solid #fff; outline-offset: 2px; box-shadow: 0 0 0 7px rgba(0,0,0,.85); }
.qh-row { display: flex; gap: 10px; align-items: flex-end; padding: 8px 4px; overflow: visible; }
.qh-tile { flex: none; width: 86px; height: 129px; border-radius: 6px; background: #20242b center/cover; transition: transform 120ms ease-out; display: flex; align-items: center; justify-content: center; text-align: center; font-size: 14px; font-weight: 500; }
.qh-tile.gpfocus { transform: scale(1.12); transform-origin: bottom left; outline: 3px solid #fff; box-shadow: 0 0 0 5px rgba(0,0,0,.85); z-index: 2; }
.qh-tabs { display: flex; gap: 20px; margin-top: 6px; align-items: baseline; }
.qh-hints { margin-left: auto; font-size: 14px; font-weight: 500; color: rgba(255,255,255,.72); }
.qh-tab { font-size: 16px; font-weight: 500; color: rgba(255,255,255,.72); padding-bottom: 2px; border-bottom: 2px solid transparent; }
.qh-tab.on { color: #fff; font-weight: 600; border-bottom-color: #fff; }
.qh-download { position: absolute; top: 9px; right: 300px; font-size: 14px; font-weight: 600; background: rgba(255,255,255,.14); border-radius: 6px; padding: 3px 9px; }
.qh-brand { position: absolute; top: 10px; left: 28px; font-size: 18px; font-weight: 600; }
@media (prefers-reduced-motion: reduce) { .qh-tile { transition: none; } }
`

/** Linha de capas, tile Loja no fim, abas com L1/R1. Foco inicial na primeira capa. */
export function QuietHome({ tabs: initial }: { tabs: Tab[] }) {
  const [tabs, setTabs] = useState(initial)
  const [tabIndex, setTabIndex] = useState(0)
  const [focused, setFocused] = useState<Game | undefined>(initial[0]?.games[0])
  const [download, setDownload] = useState<number | null>(downloadPercent())
  const [, redraw] = useState(0)
  const tab = tabs[tabIndex] ?? tabs[0]
  // Sem isto o Steam só marca o foco no primeiro comando, e a capa inicial fica sem anel.
  const firstTile = useRef<any>(null)
  const root = useRef<HTMLDivElement>(null)

  // A barra nativa (bateria, Wi-Fi, relógio) é acesa pela home nativa ao rolar; aqui ela fica sempre visível.
  useEffect(() => {
    const doc = root.current?.ownerDocument
    const header = doc && [...doc.querySelectorAll<HTMLElement>('.GamepadMode.Panel.Focusable')].find((e) => {
      const r = e.getBoundingClientRect()
      return r.y === 0 && r.height < 80 && doc.defaultView?.getComputedStyle(e).position === 'absolute'
    })
    if (!header) return
    const previous = header.style.opacity
    const show = () => { header.style.opacity = '1' }
    show()
    const timer = setInterval(() => {
      show()
      setDownload(downloadPercent())
      redraw((n) => n + 1)
    }, 2000)
    return () => {
      clearInterval(timer)
      header.style.opacity = previous
    }
  }, [])

  useEffect(() => {
    const timer = setTimeout(() => firstTile.current?.TakeFocus?.(), 150)
    return () => clearTimeout(timer)
  }, [tabIndex])

  useEffect(() => {
    const fresh = loadTabs()
    if (fresh) setTabs(fresh)
  }, [tabIndex])

  useEffect(() => {
    if (focused) requestDetails(focused.appid)
  }, [focused])

  const change = (delta: number) => {
    const next = (tabIndex + delta + tabs.length) % tabs.length
    setTabIndex(next)
    setFocused(tabs[next].games[0])
  }

  const onButtonDown = (e: any) => {
    if (e.detail.button === GamepadButton.BUMPER_LEFT) change(-1)
    if (e.detail.button === GamepadButton.BUMPER_RIGHT) change(1)
  }

  const ach = useMemo(() => (focused ? achievements(focused.appid) : null), [focused, tabs, download])

  return (
    <div className="qh" ref={root}>
      <style>{styles}</style>
      {focused && focused.heroes.length > 0 && <div className="qh-art" style={{ backgroundImage: focused.heroes.map((u) => `url("${u}")`).join(', ') }} />}
      <div className="qh-scrim" />
      <div className="qh-brand">Quiet</div>
      {download !== null && <div className="qh-download">↓ {download}%</div>}
      <Focusable className="qh-body" onButtonDown={onButtonDown}>
        <div className="qh-info">
          {focused && (
            <>
              <div className="qh-title">{focused.name}</div>
              <div className="qh-meta">{playedLine(focused)}</div>
              {ach && <div className="qh-meta">{ach}</div>}
              <Focusable className="qh-play" onActivate={() => play(focused.appid)}>▶ Jogar</Focusable>
            </>
          )}
        </div>
        <Focusable className="qh-row" flow-children="row">
          {tab.games.map((g, i) => (
            <Focusable
              key={g.appid}
              navRef={i === 0 ? firstTile : undefined}
              focusable
              className="qh-tile"
              style={{ backgroundImage: g.portrait ? `url("${g.portrait}")` : undefined }}
              onGamepadFocus={() => setFocused(g)}
              onActivate={() => Navigation.Navigate(`/library/app/${g.appid}`)}
              onOKActionDescription="Detalhes"
            >
              {g.portrait ? null : g.name}
            </Focusable>
          ))}
          <Focusable className="qh-tile" onActivate={openStore} onOKActionDescription="Abrir a Loja">Loja</Focusable>
        </Focusable>
        <div className="qh-tabs">
          {tabs.map((t, i) => <div key={t.id} className={`qh-tab ${i === tabIndex ? 'on' : ''}`}>{t.title}</div>)}
          <div className="qh-hints">L1 R1 Abas   ···  Menu rápido</div>
        </div>
      </Focusable>
    </div>
  )
}
