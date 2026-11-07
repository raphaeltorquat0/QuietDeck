// Leitura dos dados do cliente Steam. Tudo aqui é opcional: um cliente novo pode mudar esses objetos,
// e quem chama trata `null` caindo para a home nativa.

export interface Game {
  appid: number
  name: string
  lastPlayed: number
  minutes: number
  /** Camadas de CSS: o Steam lista `.jpg` e `.png` da arte personalizada, e só uma existe. */
  portraits: string[]
  /** Em ordem de preferência; o CSS usa a primeira que carregar. */
  heroes: string[]
  nonSteam: boolean
}

export interface Tab {
  id: string
  title: string
  games: Game[]
}

type Overview = any
declare const collectionStore: any
declare const appStore: any
declare const appDetailsStore: any
declare const downloadsStore: any
declare const SteamClient: any

const NON_STEAM = 1073741824

function toGame(o: Overview): Game {
  let portraits: string[] = []
  const heroes: string[] = []
  // Atalho não tem capa na loja: a URL padrão aponta para um arquivo que não existe e o tile ficava vazio.
  // Só a arte personalizada (a que o QuietDeck grava em grid/) vale; sem ela, a home desenha o tile.
  try {
    portraits = o.app_type === NON_STEAM ? appStore.GetCustomVerticalCapsuleURLs?.(o) ?? [] : [appStore.GetVerticalCapsuleURLForApp(o)].filter(Boolean)
  } catch (e) {
    console.error('[Quiet Home] capa', o.appid, e)
  }
  try {
    heroes.push(...(appStore.GetCustomHeroImageURLs?.(o) ?? []))
  } catch {}
  if (o.app_type !== NON_STEAM) heroes.push(`https://shared.steamstatic.com/store_item_assets/steam/apps/${o.appid}/library_hero.jpg`)
  return {
    appid: o.appid,
    name: o.display_name,
    lastPlayed: o.rt_last_time_played ?? 0,
    minutes: o.minutes_playtime_forever ?? 0,
    portraits,
    heroes,
    nonSteam: o.app_type === NON_STEAM,
  }
}

function list(collection: any, limit = 30): Game[] {
  const apps: Overview[] = collection?.visibleApps ?? collection?.allApps ?? []
  // Atalho nunca aberto é jogo recém-enviado: vem primeiro, com o foco, até ser jogado.
  const rank = (o: Overview) => (o.app_type === NON_STEAM && !o.rt_last_time_played ? Infinity : o.rt_last_time_played ?? 0)
  return [...apps].sort((a, b) => (rank(a) === rank(b) ? 0 : rank(b) - rank(a))).slice(0, limit).map(toGame)
}

/** Instalados, Favoritos, Emuladores (só com atalhos não-Steam) e Todos. `null` se o cliente mudou. */
/** Matiz estável por nome, para o tile desenhado de um jogo sem capa. */
export function hue(name: string): number {
  let h = 0
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) % 360
  return h
}

export function loadTabs(): Tab[] | null {
  try {
    // `allGamesCollection` e `localGamesCollection` não trazem atalhos; `myGamesCollection` traz.
    const nonSteam: Overview[] = (collectionStore.myGamesCollection.visibleApps ?? []).filter((o: Overview) => o.app_type === NON_STEAM)
    const installed = list({ visibleApps: [...(collectionStore.localGamesCollection.visibleApps ?? []), ...nonSteam] })
    const all = list(collectionStore.myGamesCollection)
    let favorites: Game[] = []
    try {
      favorites = list(collectionStore.GetCollection('favorite'))
    } catch {}
    const emulators = list({ visibleApps: nonSteam })
    const tabs: Tab[] = [{ id: 'installed', title: 'Instalados', games: installed }, { id: 'favorites', title: 'Favoritos', games: favorites }]
    if (emulators.length > 0) tabs.push({ id: 'emulators', title: 'Emuladores', games: emulators })
    tabs.push({ id: 'all', title: 'Todos', games: all })
    return tabs
  } catch {
    return null
  }
}

/** "Jogado há 2 dias · 14 h". */
export function playedLine(g: Game, now = Date.now() / 1000): string {
  const hours = Math.round(g.minutes / 60)
  const total = hours > 0 ? `${hours} h` : g.minutes > 0 ? `${g.minutes} min` : ''
  if (!g.lastPlayed) return total ? `Nunca jogado neste Deck · ${total}` : 'Ainda não jogado'
  const days = Math.floor((now - g.lastPlayed) / 86400)
  const when = days <= 0 ? 'Jogado hoje' : days === 1 ? 'Jogado ontem' : `Jogado há ${days} dias`
  return total ? `${when} · ${total}` : when
}

/** Conquistas, nunca "progresso". `null` quando o jogo não tem ou o Steam ainda não trouxe. */
export function achievements(appid: number): string | null {
  try {
    const a = appDetailsStore.GetAppDetails(appid)?.achievements ?? appDetailsStore.GetAchievements?.(appid)
    if (!a?.nTotal) return null
    return `${Math.round((a.nAchieved / a.nTotal) * 100)}% das conquistas`
  } catch {
    return null
  }
}

/** Os detalhes só chegam enquanto há registro, e as conquistas vêm depois deles: pedir uma vez só,
 *  cedo demais, perde a resposta. Repete até chegar, enquanto o jogo estiver em foco. */
/** Hero da loja pelo nome com hash, que os jogos novos exigem: a URL sem hash dá erro. Os detalhes chegam pelo `watchDetails`. */
export function storeHero(appid: number): string | null {
  try {
    const f = appDetailsStore.GetAppData?.(appid)?.details?.libraryAssets?.strHeroImage
    return f ? `https://shared.steamstatic.com/store_item_assets/steam/apps/${appid}/${f}` : null
  } catch (e) {
    console.error('[Quiet Home] hero', appid, e)
    return null
  }
}

export function watchDetails(appid: number, changed: () => void): () => void {
  try {
    const registration = appDetailsStore.RegisterForAppData(appid, changed)
    const ask = () => {
      if (appDetailsStore.GetAppDetails(appid)?.achievements?.nTotal) {
        clearInterval(timer)
        changed()
        return
      }
      appDetailsStore.GetAchievements?.(appid)
      appDetailsStore.RequestAchievements?.(appid)
    }
    const timer = setInterval(ask, 700)
    const stop = setTimeout(() => clearInterval(timer), 15000)
    ask()
    return () => {
      clearInterval(timer)
      clearTimeout(stop)
      registration?.unregister?.()
    }
  } catch {
    return () => {}
  }
}

/** Percentual do download ativo. `null` sem fila: o indicador só existe com fila ativa. */
export function downloadPercent(): number | null {
  try {
    const d = downloadsStore?.m_DownloadOverview
    if (!d?.update_appid || !d.update_bytes_to_download) return null
    return Math.round(((d.update_bytes_processed ?? d.update_bytes_downloaded ?? 0) / d.update_bytes_to_download) * 100)
  } catch {
    return null
  }
}

export function play(appid: number) {
  SteamClient.Apps.RunGame(String(appid), '', -1, 100)
}

export function openStore() {
  SteamClient.URL.ExecuteSteamURL('steam://store')
}
