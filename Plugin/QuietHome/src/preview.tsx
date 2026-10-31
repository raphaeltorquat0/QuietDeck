import { QUIET_HOME, QuietRoute } from './home'

// Só para testar no Deck sem instalar: a rota fica na memória até o Steam reiniciar.
;(window as any).__quietHomePreview = { path: QUIET_HOME, route: QuietRoute }

export default {}
