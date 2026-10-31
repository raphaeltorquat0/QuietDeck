// Roda com `node --test tests/`. Compila src/theme.ts em memória, sem dependência nova.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import ts from 'typescript'

const source = readFileSync(new URL('../src/theme.ts', import.meta.url), 'utf8')
const { outputText } = ts.transpileModule(source, { compilerOptions: { module: 'ESNext', target: 'ES2020' } })
const { createThemeSync, desiredPatch } = await import(`data:text/javascript,${encodeURIComponent(outputText)}`)

/** CSS Loader e Steam falsos. `apps` imita `RunningApps`, com o atraso medido no Deck real. */
function fakeDeck({ failures = 0 } = {}) {
  const deck = { apps: [], forced: false, patch: 'Vidro', calls: [], logs: [], pending: failures }
  deck.theme = createThemeSync({
    setPatch: async (value) => {
      deck.calls.push(value)
      if (deck.pending > 0) {
        deck.pending--
        throw new Error('Python KeyError')
      }
      deck.patch = value
      return { success: true, result: { success: true, message: 'Success' } }
    },
    running: () => deck.apps.length > 0,
    forced: () => deck.forced,
    wait: async () => {
      deck.onWait?.()
      deck.onWait = undefined
    },
    log: (message) => deck.logs.push(message),
  })
  return deck
}

test('vidro fora de jogo, opaco em jogo, salvo se forçado', () => {
  assert.equal(desiredPatch(false, false), 'Vidro')
  assert.equal(desiredPatch(true, false), 'Opaco')
  assert.equal(desiredPatch(true, true), 'Vidro')
})

test('abrir e fechar jogo Steam', async () => {
  const deck = fakeDeck()
  deck.apps = [4146670]
  await deck.theme.onAppEvent()
  assert.equal(deck.patch, 'Opaco')
  deck.apps = []
  await deck.theme.onAppEvent()
  assert.equal(deck.patch, 'Vidro')
})

test('jogo não-Steam: RunningApps ainda traz o app no evento de saída', async () => {
  const deck = fakeDeck()
  deck.apps = [3209495614]
  await deck.theme.onAppEvent()
  assert.equal(deck.patch, 'Opaco')
  deck.onWait = () => (deck.apps = [])
  await deck.theme.onAppEvent()
  assert.equal(deck.patch, 'Vidro')
})

test('largada oscila entre aberto, fechado e aberto', async () => {
  const deck = fakeDeck()
  for (const apps of [[1], [], [1]]) {
    deck.apps = apps
    await deck.theme.onAppEvent()
  }
  assert.equal(deck.patch, 'Opaco')
})

test('dois jogos: fechar um mantém opaco', async () => {
  const deck = fakeDeck()
  deck.apps = [1, 2]
  await deck.theme.onAppEvent()
  deck.apps = [2]
  await deck.theme.onAppEvent()
  assert.equal(deck.patch, 'Opaco')
})

test('jogo que trava: Steam tira da lista e volta ao vidro', async () => {
  const deck = fakeDeck()
  deck.apps = [1]
  await deck.theme.onAppEvent()
  deck.apps = []
  await deck.theme.onAppEvent()
  assert.equal(deck.patch, 'Vidro')
})

test('reiniciar o Decky com jogo aberto: lê o estado, sem depender de evento', async () => {
  const deck = fakeDeck()
  deck.patch = 'Vidro'
  deck.apps = [1]
  await deck.theme.sync()
  assert.equal(deck.patch, 'Opaco')
})

test('suspender e voltar com jogo aberto mantém opaco', async () => {
  const deck = fakeDeck()
  deck.apps = [1]
  await deck.theme.onAppEvent()
  await deck.theme.onAppEvent()
  assert.equal(deck.patch, 'Opaco')
})

test('forçar vidro em jogo e soltar', async () => {
  const deck = fakeDeck()
  deck.apps = [1]
  deck.forced = true
  await deck.theme.sync()
  assert.equal(deck.patch, 'Vidro')
  deck.forced = false
  await deck.theme.sync()
  assert.equal(deck.patch, 'Opaco')
})

test('CSS Loader sobe depois: repete e usa o estado do momento', async () => {
  const deck = fakeDeck({ failures: 3 })
  deck.apps = []
  deck.onWait = () => (deck.apps = [1])
  await deck.theme.sync()
  assert.equal(deck.patch, 'Opaco')
  assert.deepEqual(deck.logs, [])
})

test('falha definitiva é registrada, não engolida', async () => {
  const deck = fakeDeck({ failures: 99 })
  await deck.theme.sync()
  assert.equal(deck.calls.length, 15)
  assert.equal(deck.logs.length, 1)
  assert.match(deck.logs[0], /Python KeyError/)
})

test('tema ausente responde success false e também é registrado', async () => {
  const logs = []
  const sync = createThemeSync({
    setPatch: async () => ({ success: true, result: { success: false, message: 'No theme named Quiet Glass' } }),
    running: () => false,
    forced: () => false,
    wait: async () => {},
    log: (message) => logs.push(message),
  })
  await sync.sync()
  assert.match(logs[0], /No theme named/)
})
