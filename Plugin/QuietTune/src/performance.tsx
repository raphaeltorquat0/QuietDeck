import { callable } from '@decky/api'
import { ButtonItem, PanelSection, PanelSectionRow, SliderField, ToggleField } from '@decky/ui'
import { useEffect, useState } from 'react'

type Result<T> = { ok: true; value: T } | { ok: false; error: string }
type Limits = { label: string; tdp_min: number; tdp_max: number; gpu_min: number; gpu_max: number }
type State = { tdp: number; gpu: string; gpu_min: number | null; gpu_max: number | null }
type Info = { supported: false } | { supported: true; limits: Limits; state: State; custom: boolean }

const getState = callable<[], Result<Info>>('get_state')
const setProfile = callable<[profile: object], Result<null>>('set_profile')
const restoreDefaults = callable<[], Result<null>>('restore_defaults')
export const reapply = callable<[], Result<boolean>>('reapply')

/** Desempenho: a validação de verdade é do backend. Aqui só refletimos o que ele devolve. */
export function PerformancePanel() {
  const [info, setInfo] = useState<Info>()
  const [error, setError] = useState('')

  const report = (result: Result<unknown>) => {
    setError(result.ok ? '' : result.error)
    if (!result.ok) console.error('QuietTune:', result.error)
    return result.ok
  }
  const refresh = async () => {
    const result = await getState()
    if (report(result) && result.ok) setInfo(result.value)
  }
  const send = async (action: Promise<Result<null>>) => {
    report(await action)
    await refresh()
  }
  useEffect(() => {
    refresh().catch((reason) => setError(String(reason)))
  }, [])

  if (!info) return error ? <PanelSection title="Desempenho">{error}</PanelSection> : null
  if (!info.supported) return <PanelSection title="Desempenho">Este aparelho não é um Steam Deck conhecido.</PanelSection>

  const { limits, state, custom } = info
  const manual = state.gpu === 'manual' && custom
  const profile = (tdp: number, gpu: number | null) =>
    gpu === null ? { tdp, gpu: 'auto' } : { tdp, gpu: 'manual', gpu_min: gpu, gpu_max: gpu }

  return (
    <PanelSection title={`Desempenho (${limits.label})`}>
      <PanelSectionRow>
        <SliderField
          label="Limite de TDP"
          value={state.tdp}
          min={limits.tdp_min}
          max={limits.tdp_max}
          step={1}
          showValue
          valueSuffix=" W"
          onChange={(tdp) => void send(setProfile(profile(tdp, manual ? state.gpu_max : null)))}
        />
      </PanelSectionRow>
      <PanelSectionRow>
        <ToggleField
          label="Clock de GPU fixo"
          checked={manual}
          onChange={(on) => void send(setProfile(profile(state.tdp, on ? limits.gpu_max : null)))}
        />
      </PanelSectionRow>
      {manual && (
        <PanelSectionRow>
          <SliderField
            label="Clock de GPU"
            value={state.gpu_max ?? limits.gpu_max}
            min={limits.gpu_min}
            max={limits.gpu_max}
            step={50}
            showValue
            valueSuffix=" MHz"
            onChange={(gpu) => void send(setProfile(profile(state.tdp, gpu)))}
          />
        </PanelSectionRow>
      )}
      <PanelSectionRow>
        <ButtonItem layout="below" description={error || undefined} onClick={() => void send(restoreDefaults())}>
          Restaurar padrão
        </ButtonItem>
      </PanelSectionRow>
    </PanelSection>
  )
}
