import { Focusable, GamepadButton, Navigation } from '@decky/ui'
import { useEffect, useRef, useState } from 'react'
import { achievements, downloadPercent, Game, hue, loadTabs, openStore, play, playedLine, storeHero, Tab, watchDetails } from './steam'

const styles = `
.qh { position: absolute; inset: 0; background: #0b0d10; color: #fff; overflow: hidden; overflow: clip; display: flex; flex-direction: column; }
.qh-art { position: absolute; top: 0; left: 0; right: 0; aspect-ratio: 1920 / 620; background-size: cover; background-position: center top; -webkit-mask-image: linear-gradient(#000 60%, transparent); }
.qh-scrim { position: absolute; inset: 0; background: linear-gradient(to right, rgba(0,0,0,.86) 0%, rgba(0,0,0,.55) 55%, rgba(0,0,0,.3) 100%), linear-gradient(to top, rgba(0,0,0,.92) 0%, rgba(0,0,0,.45) 55%, rgba(0,0,0,.45) 100%); }
.qh-body { position: relative; flex: 1; display: flex; flex-direction: column; padding: 56px 28px 44px; min-height: 0; min-width: 0; overflow: hidden; }
.qh-info { flex: 1; min-height: 0; }
.qh-title { font-size: 30px; font-weight: 600; line-height: 1.15; margin-bottom: 6px; text-shadow: 0 1px 4px rgba(0,0,0,.6); }
.qh-meta { font-size: 16px; font-weight: 500; line-height: 1.35; }
.qh-play { display: inline-flex; margin-top: 12px; background: #fff; color: #0b0d10; border-radius: 8px; padding: 7px 20px; font-size: 16px; font-weight: 600; }
.qh-play.gpfocus, .qh-play:focus { outline: 3px solid #fff; outline-offset: 2px; box-shadow: 0 0 0 7px rgba(0,0,0,.85); }
.qh-row { display: flex; gap: 10px; align-items: flex-end; padding: 22px 14px 10px; margin: 0 -14px; overflow-x: auto; overflow-y: hidden; flex: none; scroll-padding-inline: 20px; }
/* O tile em foco cresce 10%: sem margem na rolagem, o da ponta encostava na borda e era cortado. */
.qh-row::-webkit-scrollbar { display: none; }
.qh-row::after { content: ''; flex: none; width: 16px; }
.qh-tile { box-sizing: border-box; flex: none; width: 112px; height: 168px; border-radius: 6px; background: #20242b center/cover; transition: transform 120ms ease-out; display: flex; align-items: center; justify-content: center; text-align: center; font-size: 14px; font-weight: 500; }
.qh-tile.gpfocus, .qh-tile:focus { transform: scale(1.1); transform-origin: bottom center; outline: 3px solid #fff; box-shadow: 0 0 0 5px rgba(0,0,0,.85); z-index: 2; }
.qh-tabs { display: flex; gap: 20px; margin-top: 6px; align-items: baseline; padding: 6px 14px; border-radius: 12px; background: rgba(14,16,20,.55); backdrop-filter: blur(18px) saturate(140%); }
.qh-tab { font-size: 16px; font-weight: 500; color: rgba(255,255,255,.72); padding-bottom: 2px; border-bottom: 2px solid transparent; }
.qh-tab.on { color: #fff; font-weight: 600; border-bottom-color: #fff; }
.qh-download { margin-left: auto; font-size: 14px; font-weight: 600; color: rgba(255,255,255,.72); }
.qh-tile.qh-gen { align-items: flex-end; justify-content: flex-start; text-align: left; padding: 8px; font-size: 13px; font-weight: 700; line-height: 1.15; text-shadow: 0 1px 3px rgba(0,0,0,.5); overflow: hidden; overflow-wrap: anywhere; }
@supports not (backdrop-filter: blur(1px)) { .qh-tabs { background: #0e1014; } }
@media (prefers-reduced-transparency: reduce) { .qh-tabs { background: #0e1014; backdrop-filter: none; } }
@media (prefers-reduced-motion: reduce) { .qh-tile { transition: none; } }
`

const gradient = (name: string) => {
  const h = hue(name)
  return `linear-gradient(150deg, hsl(${h} 70% 46%) 0%, hsl(${(h + 40) % 360} 65% 18%) 100%)`
}

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

  // A barra nativa é acesa pela home nativa ao rolar, e no início do Steam ela surge depois desta tela.
  useEffect(() => {
    const doc = root.current?.ownerDocument
    let header: HTMLElement | undefined
    let brand: HTMLElement | undefined
    let previous = { opacity: '', background: '' }

    const attach = () => {
      if (header?.isConnected || !doc) return
      header = [...doc.querySelectorAll<HTMLElement>('.GamepadMode')].find((e) => {
        const r = e.getBoundingClientRect()
        return r.y === 0 && r.height > 0 && r.height < 80 && doc.defaultView?.getComputedStyle(e).position === 'absolute'
      })
      if (!header) return
      previous = { opacity: header.style.opacity, background: header.style.background }
      brand = doc.createElement('div')
      brand.textContent = 'Quiet'
      brand.style.cssText = 'position:absolute;left:28px;top:10px;font-size:18px;font-weight:600;color:#fff;pointer-events:none'
      header.appendChild(brand)
    }

    const tick = () => {
      attach()
      if (header) {
        header.style.opacity = '1'
        header.style.background = 'transparent'
      }
    }

    tick()
    const fast = setInterval(tick, 300)
    const stopFast = setTimeout(() => clearInterval(fast), 15000)
    const timer = setInterval(() => {
      tick()
      setDownload(downloadPercent())
      redraw((n) => n + 1)
    }, 2000)
    return () => {
      clearInterval(fast)
      clearTimeout(stopFast)
      clearInterval(timer)
      brand?.remove()
      if (header) {
        header.style.opacity = previous.opacity
        header.style.background = previous.background
      }
    }
  }, [])

  useEffect(() => {
    const timers = [150, 500, 1000].map((ms) => setTimeout(() => {
      if (!root.current?.querySelector('.qh-row .gpfocus')) firstTile.current?.TakeFocus?.()
    }, ms))
    return () => timers.forEach(clearTimeout)
  }, [tabIndex])

  useEffect(() => (focused ? watchDetails(focused.appid, () => redraw((n) => n + 1)) : undefined), [focused])

  // Recarrega antes de calcular o índice: a aba Emuladores pode ter surgido ou sumido, e o
  // índice antigo apontaria para outra aba. A aba atual é achada pelo id.
  const change = (delta: number) => {
    const fresh = loadTabs() ?? tabs
    const current = Math.max(0, fresh.findIndex((t) => t.id === tab.id))
    const next = (current + delta + fresh.length) % fresh.length
    setTabs(fresh)
    setTabIndex(next)
    setFocused(fresh[next].games[0])
  }

  const onButtonDown = (e: any) => {
    if (e.detail.button === GamepadButton.BUMPER_LEFT) change(-1)
    if (e.detail.button === GamepadButton.BUMPER_RIGHT) change(1)
  }

  // Sem memo: as conquistas chegam depois do primeiro desenho, e o timer de 2 s redesenha.
  const ach = focused ? achievements(focused.appid) : null

  return (
    <div className="qh" ref={root}>
      <style>{styles}</style>
      {/* Camada que não carrega fica transparente; o gradiente no fundo cobre a falta de todas. */}
      {focused && <div className="qh-art" style={{ backgroundImage: [...focused.heroes, storeHero(focused.appid)].filter(Boolean).map((u) => `url("${u}")`).concat(gradient(focused.name)).join(', ') }} />}
      <div className="qh-scrim" />
      <Focusable className="qh-body" onButtonDown={onButtonDown} actionDescriptionMap={{ [GamepadButton.BUMPER_LEFT]: 'Aba anterior', [GamepadButton.BUMPER_RIGHT]: 'Próxima aba' }}>
        <div className="qh-info">
          {focused && (
            <>
              <div className="qh-title">{focused.name}</div>
              <div className="qh-meta">{playedLine(focused)}</div>
              {ach && <div className="qh-meta">{ach}</div>}
              <Focusable className="qh-play" noFocusRing onActivate={() => play(focused.appid)}>▶ Jogar</Focusable>
            </>
          )}
        </div>
        <Focusable className="qh-row" flow-children="row">
          {tab.games.map((g, i) => (
            <Focusable
              key={g.appid}
              navRef={i === 0 ? firstTile : undefined}
              focusable
              noFocusRing
              className={g.portraits.length ? 'qh-tile' : 'qh-tile qh-gen'}
              // Camada que não carrega fica transparente; o gradiente por baixo cobre a falta de todas.
              style={{ backgroundImage: [...g.portraits.map((u) => `url("${u}")`), gradient(g.name)].join(', ') }}
              onGamepadFocus={() => setFocused(g)}
              onActivate={() => Navigation.Navigate(`/library/app/${g.appid}`)}
              onOKActionDescription="Detalhes"
            >
              {g.portraits.length ? null : g.name}
            </Focusable>
          ))}
          <Focusable className="qh-tile" noFocusRing onActivate={openStore} onOKActionDescription="Abrir a Loja">Loja</Focusable>
        </Focusable>
        <div className="qh-tabs">
          {tabs.map((t, i) => <div key={t.id} className={`qh-tab ${i === tabIndex ? 'on' : ''}`} onClick={() => change(i - tabIndex)}>{t.title}</div>)}
          {download !== null && <div className="qh-download">↓ {download}%</div>}
        </div>
      </Focusable>
    </div>
  )
}
