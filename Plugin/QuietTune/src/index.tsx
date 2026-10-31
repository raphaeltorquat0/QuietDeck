import { definePlugin } from '@decky/api'
import { PanelSection, PanelSectionRow, Router, ToggleField } from '@decky/ui'
import { useState } from 'react'
import { PerformancePanel, reapply } from './performance'
import { createThemeSync, PATCH, THEME } from './theme'

declare const SteamClient: any
declare const DeckyBackend: any

const FORCE = 'quiettune-force'

const forced = () => localStorage.getItem(FORCE) === '1'

const reportError = (message: string) => console.error('QuietTune:', message)

const theme = createThemeSync({
  /** Mesmo caminho do painel do CSS Loader. O servidor local dele fica desligado e aberto a qualquer página. */
  setPatch: (value) =>
    DeckyBackend.call('loader/call_legacy_plugin_method', 'CSS Loader', 'set_patch_of_theme', {
      themeName: THEME,
      patchName: PATCH,
      value,
    }),
  running: () => (Router.RunningApps?.length ?? 0) > 0,
  forced,
  wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  log: reportError,
})

function ThemePanel() {
  const [checked, setChecked] = useState(forced)
  return (
    <PanelSection title="Vidro">
      <PanelSectionRow>
        <ToggleField
          label="Vidro sempre"
          description="Mantém o vidro no menu rápido durante o jogo. Pode custar FPS e bateria."
          checked={checked}
          onChange={(value) => {
            setChecked(value)
            localStorage.setItem(FORCE, value ? '1' : '0')
            void theme.sync()
          }}
        />
      </PanelSectionRow>
    </PanelSection>
  )
}

/** Steam e steamos-manager reescrevem TDP e clock ao trocar de jogo e ao voltar da suspensão. */
async function keepProfile() {
  await new Promise((resolve) => setTimeout(resolve, 3000))
  try {
    const result = await reapply()
    if (!result.ok) reportError(result.error)
  } catch (error) {
    reportError(String(error))
  }
}

export default definePlugin(() => {
  void theme.sync()
  void keepProfile()
  const onChange = () => {
    void theme.onAppEvent()
    void keepProfile()
  }
  const lifetime = SteamClient.GameSessions.RegisterForAppLifetimeNotifications(onChange)
  const resume = SteamClient.User.RegisterForResumeSuspendedGamesProgress?.(onChange)
  return {
    name: 'QuietTune',
    icon: <span>Q</span>,
    content: (
      <>
        <ThemePanel />
        <PerformancePanel />
      </>
    ),
    onDismount() {
      lifetime?.unregister?.()
      resume?.unregister?.()
    },
  }
})
