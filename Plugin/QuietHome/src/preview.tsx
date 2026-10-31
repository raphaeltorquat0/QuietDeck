import { homePatch } from './patch'

// Só para testar no Deck sem instalar: o patch fica na memória até o Steam reiniciar.
;(window as any).__quietHomePreview = homePatch

export default {}
