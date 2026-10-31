import { definePlugin } from '@decky/api'
import { PanelSection, PanelSectionRow, Router, ToggleField } from '@decky/ui'
import { useState } from 'react'

declare const SteamClient: any
declare const DeckyBackend: any

const FORCE = 'quiettune-force'
const apps = new Set<number>()

const force = () => localStorage.getItem(FORCE) === '1'

/** Mesmo caminho do painel do CSS Loader. O servidor local dele fica desligado e aberto a qualquer página. */
const setPatch = (value: string) =>
  DeckyBackend.call('loader/call_legacy_plugin_method', 'CSS Loader', 'set_patch_of_theme', {
    themeName: 'Quiet Glass',
    patchName: 'Menus',
    value,
  })

/** No boot o CSS Loader pode subir depois deste plugin. A tentativa seguinte usa o estado do momento. */
async function apply(tries = 15) {
  try {
    await setPatch(force() || apps.size === 0 ? 'Vidro' : 'Opaco')
  } catch {
    if (tries > 0) setTimeout(() => void apply(tries - 1), 1000)
  }
}

function Panel() {
  const [checked, setChecked] = useState(force)
  return (
    <PanelSection>
      <PanelSectionRow>
        <ToggleField
          label="Vidro sempre"
          description="Mantém o vidro no menu rápido durante o jogo. Pode custar FPS e bateria."
          checked={checked}
          onChange={(value) => {
            setChecked(value)
            localStorage.setItem(FORCE, value ? '1' : '0')
            void apply()
          }}
        />
      </PanelSectionRow>
    </PanelSection>
  )
}

export default definePlugin(() => {
  apps.clear()
  const running = Router.MainRunningApp?.appid
  if (running) apps.add(Number(running))
  void apply()
  const registration = SteamClient.GameSessions.RegisterForAppLifetimeNotifications(
    (update: { unAppID: number; bRunning: boolean }) => {
      if (update.bRunning) apps.add(update.unAppID)
      else apps.delete(update.unAppID)
      void apply()
    },
  )
  return {
    name: 'QuietTune',
    icon: <span>Q</span>,
    content: <Panel />,
    onDismount() {
      registration?.unregister?.()
    },
  }
})
