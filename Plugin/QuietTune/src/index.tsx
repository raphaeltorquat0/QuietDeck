import { callable, definePlugin } from '@decky/api'
import { PanelSection, PanelSectionRow, Router, ToggleField } from '@decky/ui'
import { useEffect, useState } from 'react'

declare const SteamClient: any

const setRunning = callable<[running: boolean], void>('set_running')
const getForce = callable<[], boolean>('get_force')
const setForce = callable<[force: boolean], void>('set_force')

function Panel() {
  const [force, setValue] = useState(false)
  useEffect(() => {
    void getForce().then(setValue)
  }, [])
  return (
    <PanelSection>
      <PanelSectionRow>
        <ToggleField
          label="Vidro sempre"
          description="Mantém o vidro no menu rápido durante o jogo. Pode custar FPS e bateria."
          checked={force}
          onChange={(value) => {
            setValue(value)
            void setForce(value)
          }}
        />
      </PanelSectionRow>
    </PanelSection>
  )
}

export default definePlugin(() => {
  const apps = new Set<number>()
  const running = Router.MainRunningApp?.appid
  if (running) apps.add(Number(running))
  void setRunning(apps.size > 0)
  const registration = SteamClient.GameSessions.RegisterForAppLifetimeNotifications(
    (update: { unAppID: number; bRunning: boolean }) => {
      if (update.bRunning) apps.add(update.unAppID)
      else apps.delete(update.unAppID)
      void setRunning(apps.size > 0)
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
