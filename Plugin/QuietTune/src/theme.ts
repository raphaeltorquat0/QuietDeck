/** Tema: troca o patch de Quiet Glass conforme há jogo aberto. Sem nada de desempenho aqui. */
export const THEME = 'Quiet Glass'
export const PATCH = 'Menus'
const ATTEMPTS = 15
const SETTLE_MS = 2500

export type ThemeDeps = {
  /** Resposta de `call_legacy_plugin_method` para `set_patch_of_theme`. */
  setPatch: (value: string) => Promise<{ success?: boolean; result?: { success?: boolean; message?: string } }>
  running: () => boolean
  forced: () => boolean
  wait: (ms: number) => Promise<void>
  log: (message: string) => void
}

export const desiredPatch = (running: boolean, forced: boolean) => (forced || !running ? 'Vidro' : 'Opaco')

/**
 * O estado do Steam é a fonte de verdade: serve depois de reiniciar o Decky e cobre jogo que trava.
 * As chamadas entram em fila e cada tentativa lê o estado do momento, então a última vence.
 */
export function createThemeSync(deps: ThemeDeps) {
  let queue: Promise<void> = Promise.resolve()

  async function attempt() {
    let failure = ''
    for (let tries = ATTEMPTS; tries > 0; tries--) {
      const value = desiredPatch(deps.running(), deps.forced())
      try {
        const response = await deps.setPatch(value)
        if (response.success && response.result?.success) return
        failure = JSON.stringify(response)
      } catch (error) {
        failure = String(error)
      }
      // No boot o CSS Loader pode subir depois deste plugin.
      if (tries > 1) await deps.wait(1000)
    }
    deps.log(`CSS Loader recusou a troca do patch: ${failure}`)
  }

  const sync = () => (queue = queue.then(attempt))

  return {
    sync,
    /** O `RunningApps` de um app não-Steam fica até 2 s atrás do evento, medido no Deck real. */
    async onAppEvent() {
      await sync()
      await deps.wait(SETTLE_MS)
      await sync()
    },
  }
}
