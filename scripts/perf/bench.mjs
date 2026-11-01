#!/usr/bin/env node
// Medição do Quiet Glass no Deck real. Só abre e fecha o que ela mesma iniciou e recusa começar com jogo aberto.
// Uso: QD_SSH=<script ssh> node --experimental-websocket scripts/perf/bench.mjs <pasta de saída>, com a porta 8080 do Deck em 127.0.0.1:9222.
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const OUT = process.argv[2]
const SSH = process.env.QD_SSH
const SCALE = Number(process.env.QD_SCALE ?? 1) // 0.02 para ensaiar o roteiro em segundos.
const REMOTE = '/tmp/qd-bench'
const DIM = 30000
const IDLE = 'system_idle_suspend_battery_sec'
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const minutes = (n) => n * 60000 * SCALE
const log = (...items) => console.log(new Date().toISOString().slice(11, 19), ...items)
const ssh = (script) => execFileSync(SSH, ['bash', '-s'], { input: script, timeout: 30000 }).toString().trim()

async function session(title) {
  const list = await (await fetch('http://127.0.0.1:9222/json')).json()
  const target = list.find((t) => t.title.startsWith(title))
  if (!target) throw new Error(`alvo ausente: ${title}`)
  const ws = new WebSocket(target.webSocketDebuggerUrl)
  await new Promise((resolve) => (ws.onopen = resolve))
  let id = 0
  const pending = new Map()
  ws.onmessage = (event) => {
    const message = JSON.parse(event.data)
    pending.get(message.id)?.(message.result)
    pending.delete(message.id)
  }
  const ev = (expression) =>
    new Promise((resolve) => {
      pending.set(++id, (result) => resolve(result?.result?.value))
      ws.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { expression, awaitPromise: true, returnByValue: true } }))
    })
  return { ev, close: () => ws.close() }
}

let shared = await session('SharedJSContext')
const running = async () => JSON.parse(await shared.ev('JSON.stringify((DFL.Router.RunningApps||[]).map(a=>a.appid))'))
const css = (method, args = '{}') =>
  shared.ev(`DeckyBackend.call('loader/call_legacy_plugin_method','CSS Loader','${method}',${args}).then(r=>JSON.stringify(r),e=>JSON.stringify({error:String(e)}))`)

/** Confere o patch ativo no próprio CSS Loader: a medição não pode depender de a troca ter dado certo. */
async function setPatch(value) {
  const answer = JSON.parse(await css('set_patch_of_theme', `{themeName:'Quiet Glass',patchName:'Menus',value:'${value}'}`))
  if (!answer.result?.success) throw new Error(`troca recusada: ${JSON.stringify(answer)}`)
  await sleep(1200)
  const theme = JSON.parse(await css('get_themes')).result.find((t) => t.name === 'Quiet Glass')
  const active = theme?.patches.find((p) => p.name === 'Menus')?.value
  if (!theme?.enabled || active !== value) throw new Error(`patch ativo ${active}, esperado ${value}`)
}

/** A captura do gamescope só pega o plano do jogo, então a prova do menu aberto é o Steam e o foco de entrada. */
async function setMenu(open) {
  await shared.ev(open ? 'DFL.Navigation.OpenQuickAccessMenu(0)' : 'DFL.Navigation.CloseSideMenus()')
  // O foco de entrada leva alguns segundos para voltar ao jogo.
  let side, focus
  for (let i = 0; i < 8; i++) {
    await sleep(1500)
    side = await shared.ev('SteamUIStore.WindowStore.GamepadUIMainWindowInstance.MenuStore.GetOpenSideMenu()')
    focus = ssh(`DISPLAY=:0 xprop -root GAMESCOPE_FOCUSED_APP 2>/dev/null | sed 's/.*= //'`)
    if (open === (side === 2) && open === (focus === '769')) return
  }
  throw new Error(`menu ${open ? 'não abriu' : 'não fechou'}: lado ${side}, foco ${focus}`)
}

/** Descarta 5 s depois da transição, e cada condição grava o próprio CSV do MangoHud. */
let sampled = 0
async function condition(label, duration, game) {
  await sleep(5000 * Math.min(SCALE * 50, 1))
  // Com o foco no Steam o mangoapp não grava nada. Melhor parar agora que descobrir ao fim do bloco.
  if (game && !label.includes('/menu-') && ssh(`DISPLAY=:0 xprop -root GAMESCOPE_FOCUSED_APP 2>/dev/null | sed 's/.*= //'`) === '769') throw new Error('foco no Steam, sem o jogo')
  ssh(`echo '${label}' > ${REMOTE}/label${game ? `; mangohudctl set log_session 1` : ''}`)
  await sleep(duration)
  const samples = Number(ssh(`wc -l < ${REMOTE}/samples.csv`))
  if (samples <= sampled) throw new Error('o coletor parou')
  sampled = samples
  ssh(`echo pausa > ${REMOTE}/label${game ? `; mangohudctl set log_session 0; sleep 1; mkdir -p ${REMOTE}/mango/${label}; mv /tmp/qd-mango/*.csv ${REMOTE}/mango/${label}/` : ''}`)
  log('feito', label)
}

/** A tela escurece sozinha e isso muda o consumo em quase 2 W, mais que o que está sendo medido. */
async function dimmed() {
  for (let i = 0; i < 48; i++) {
    if (Number(ssh('cat /sys/class/backlight/amdgpu_bl0/brightness')) < DIM) return
    await sleep(10000)
  }
  throw new Error('a tela não escureceu')
}

async function start(gameId, appId, settle) {
  await shared.ev(`SteamClient.Apps.RunGame("${gameId}","",-1,100)`)
  for (let i = 0; i < 40 && !(await running()).includes(appId); i++) await sleep(3000)
  if (!(await running()).includes(appId)) throw new Error(`não abriu: ${appId}`)
  await sleep(settle)
}

async function stop(gameId, appId) {
  await shared.ev(`SteamClient.Apps.TerminateApp("${gameId}",false)`)
  for (let i = 0; i < 30 && (await running()).length; i++) await sleep(2000)
  if ((await running()).length) throw new Error(`não fechou: ${appId}`)
  await sleep(8000)
}

async function measureGame(name, gameId, appId, settle) {
  await start(gameId, appId, settle)
  ssh(`XDG_RUNTIME_DIR=/run/user/1000 gamescopectl screenshot ${REMOTE}/${name}.png >/dev/null 2>&1 || true`)
  if (SCALE === 1) await dimmed()
  for (const rep of [1, 2]) {
    await setPatch('Opaco')
    await condition(`${name}/fechado/${rep}`, minutes(3), true)
    await setMenu(true)
    await condition(`${name}/menu-opaco/${rep}`, minutes(1), true)
    await setMenu(false)
    await setPatch('Vidro')
    await setMenu(true)
    await condition(`${name}/menu-vidro/${rep}`, minutes(1), true)
    await setMenu(false)
  }
  await setPatch('Vidro')
  await stop(gameId, appId)
}

/** Bloco único e simétrico: a tensão da bateria cai ao longo da medição. */
async function home() {
  if (SCALE === 1) {
    await dimmed()
    await sleep(minutes(10)) // Logo depois de usar o Deck a home gasta até 1,3 W a mais, com o mesmo patch.
  }
  for (const [patch, rep] of [['Vidro', 1], ['Opaco', 1], ['Opaco', 2], ['Vidro', 2]]) {
    await setPatch(patch)
    await sleep(10000 * Math.min(SCALE * 50, 1))
    await condition(`home/${patch === 'Vidro' ? 'vidro' : 'opaco'}/${rep}`, minutes(5), false)
  }
}

if ((await running()).length) throw new Error('há jogo aberto; a medição só começa com o Deck na home')
const route = await shared.ev('location.pathname')
log('início', route)
const config = ssh('ls /run/user/1000/gamescope.*/mangohud.config').split('\n')[0]
// QD_RESUME pula as etapas já medidas e mantém o que está em /tmp/qd-bench.
const done = (process.env.QD_RESUME ?? '').split(',')
const fresh = !process.env.QD_RESUME
ssh(`${fresh ? `rm -rf ${REMOTE} /tmp/qd-mango; mkdir -p ${REMOTE}; cp ${config} ${REMOTE}/mangohud.bak; ` : ''}mkdir -p /tmp/qd-mango; echo pausa > ${REMOTE}/label
grep -q qd-mango ${config} || printf 'output_folder=/tmp/qd-mango\\nlog_interval=0\\nlog_versioning=0\\n' >> ${config}
systemctl --user stop qd-sampler 2>/dev/null; systemctl --user reset-failed qd-sampler 2>/dev/null
systemd-run --user --quiet --unit=qd-sampler python3 /tmp/qd-sampler.py ${REMOTE}/samples.csv ${REMOTE}/label`)
// O SteamOS encerra o que sobra da sessão SSH: sem amostras não há medição.
await sleep(3000)
if (Number(ssh(`wc -l < ${REMOTE}/samples.csv`)) < 2) throw new Error('o coletor não está gravando')

// Abrir jogo não zera a ociosidade: aos 15 minutos o Steam suspende ou, com inibidor, apaga a tela, e sem tela não há quadros.
// Fica no valor original ao terminar, mesmo com falha.
const idle = await shared.ev(`settingsStore.GetClientSetting('${IDLE}')[0]`)
const setIdle = async (seconds) => {
  await shared.ev(`settingsStore.GetClientSetting('${IDLE}')[1](${seconds})`)
  await sleep(1000)
  const now = await shared.ev(`settingsStore.GetClientSetting('${IDLE}')[0]`)
  if (now !== seconds) throw new Error(`ociosidade ${now}, esperado ${seconds}`)
}
log('ociosidade original', idle)
await setIdle(14400)

const shortcut = await shared.ev(`SteamClient.Apps.AddShortcut("QuietDeck Bench","/usr/bin/flatpak","/usr/bin","")`)
let failure
try {
  await sleep(1500)
  await shared.ev(`SteamClient.Apps.SetShortcutName(${shortcut},"QuietDeck Bench")`)
  await shared.ev(`SteamClient.Apps.SetShortcutLaunchOptions(${shortcut},"run org.libretro.RetroArch")`)
  await sleep(1500)
  const shortcutGame = await shared.ev(`appStore.GetAppOverviewByAppID(${shortcut}).GetGameID()`)
  if (!done.includes('home')) await home()
  if (!done.includes('pesado')) await measureGame('pesado', '2975950', 2975950, 75000 * Math.min(SCALE * 50, 1))
  if (!done.includes('leve')) await measureGame('leve', process.env.QD_LIGHT ?? '4146670', Number(process.env.QD_LIGHT ?? 4146670), 40000 * Math.min(SCALE * 50, 1))
  if (!done.includes('nao-steam')) await measureGame('nao-steam', shortcutGame, shortcut, 20000)
} catch (error) {
  failure = error
  log('FALHOU', error.message)
}

// A limpeza roda mesmo com falha: nada de jogo aberto, atalho ou configuração sobrando no Deck.
try {
  for (const id of await running()) await shared.ev(`SteamClient.Apps.TerminateApp("${id > 2 ** 31 ? await shared.ev(`appStore.GetAppOverviewByAppID(${id}).GetGameID()`) : id}",false)`)
  await sleep(6000)
  await shared.ev('DFL.Navigation.CloseSideMenus()')
  await shared.ev(`SteamClient.Apps.RemoveShortcut(${shortcut})`)
  await setPatch('Vidro')
} catch (error) {
  log('limpeza incompleta', error.message)
}
try {
  await setIdle(idle)
  log('ociosidade restaurada', idle)
} catch (error) {
  log('RESTAURAR À MÃO', IDLE, idle, error.message)
}
// Dados primeiro: uma queda de rede aqui não pode custar a medição, que fica em /tmp no Deck.
try {
  ssh(`rm -f ${REMOTE}/label; sleep 2; cp ${REMOTE}/mangohud.bak ${config}; rm -rf /tmp/qd-mango; cd /tmp && tar czf qd-bench.tgz qd-bench`)
  fs.mkdirSync(OUT, { recursive: true })
  fs.writeFileSync(path.join(OUT, 'qd-bench.tgz'), execFileSync(SSH, ['cat /tmp/qd-bench.tgz'], { maxBuffer: 1 << 30 }))
  if (!failure) ssh('rm -rf /tmp/qd-bench /tmp/qd-bench.tgz')
} catch (error) {
  log('dados ficaram no Deck, em /tmp/qd-bench', error.message)
}
shared.close()
log(failure ? 'terminou com falha' : 'terminou')
process.exit(failure ? 1 : 0)
