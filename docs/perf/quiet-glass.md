# Quiet Glass: FPS e consumo

Relatório gerado por `scripts/perf/report.py` com dados do Deck real. Protocolo em `SMOKE_TEST.md`.

**Medição concluída, com uma limitação no jogo pesado.** Deck LCD, SteamOS 3.9.5. Home e Alone in the Dark em 31/10/2026; Solasta II, ReStory Playtest e RetroArch em 01/11/2026, com o Steam recém-iniciado.

- Consumo é corrente vezes tensão da bateria, só descarregando. Na home contam só amostras no mesmo brilho, porque o sensor de luz ambiente muda o brilho sozinho e isso pesa mais que o medido.
- Sem controle no Deck, cada jogo fica na tela de título, com cena 3D ao vivo no Solasta II.
- Com jogo aberto, a captura do gamescope só mostra o plano do jogo. O menu aberto foi conferido pelo Steam (`GetOpenSideMenu`) e pelo foco de entrada, sem prova visual.
- Substituições: RDR2 não abriu pela API do Steam. Alone in the Dark abriu, mas trava a 30 FPS, e ficou como dado extra. O Deck não tinha atalho não-Steam: o script criou um temporário para o RetroArch, sem ROM, na tela inicial do próprio RetroArch, e removeu ao terminar.
- **Limitação do Solasta II:** a GPU ficou entre 99% e 100% ocupada, mas o jogo usa `VSync=Double` e o gamescope pôs a tela em 44 Hz cerca de 20 s depois de abrir, por motivo não identificado. O FPS fica preso em 22,0, então uma perda pequena não aparece no FPS médio; ela apareceria no 1% low, na APU ou como queda para o divisor seguinte, e nada disso ocorreu. Não alterei as configurações do jogo. Uma rodada de 31/10 chegou a 14,3 W de APU e 1600 MHz, sem FPS gravado; não reproduzi esse estado.
- O RetroArch manteve a tela sem escurecer, então o consumo dele usa todo o bloco, com brilho variando entre 32767 e 38665. Para ele a referência é a APU.

## Home parada

| Condição | Bloco | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Ventoinha (rpm) | Amostras válidas |
|---|---|---:|---:|---:|---:|---:|---:|
| Vidro | 1 | 4,24 | 3,20 | 46,7 | 45,6 | 1501 | 39/306 |
| Vidro | 2 | 3,79 | 3,10 | 45,1 | 44,1 | 1502 | 306/306 |
| Opaco | 1 | 3,97 | 3,18 | 46,2 | 45,0 | 1498 | 306/306 |
| Opaco | 2 | 3,90 | 3,16 | 45,7 | 44,6 | 1498 | 306/306 |

**Vidro menos opaco: 0,08 W em média** (por bloco: 0,27, -0,11 W). Limite: 0,3 W. **Resultado: aprovado.** Só a APU, que não depende do brilho: -0,02 W.

## Jogos

### Solasta II (VSync duplo, 22 FPS)

| Condição | Rodada | FPS médio | 1% low | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Quadros |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Menu fechado | 1 | 22,0 | 20,3 | 12,04 | 6,41 | 69,2 | 68,0 | 4097 |
| Menu fechado | 2 | 22,0 | 20,3 | 12,04 | 6,44 | 70,0 | 68,8 | 4048 |
| Menu aberto, opaco | 1 | 22,0 | 20,3 | 12,09 | 6,46 | 69,5 | 68,3 | 1475 |
| Menu aberto, opaco | 2 | 22,0 | 20,3 | 12,16 | 6,48 | 70,4 | 69,2 | 1463 |
| Menu aberto, vidro | 1 | 22,0 | 20,3 | 12,05 | 6,58 | 69,7 | 68,4 | 1459 |
| Menu aberto, vidro | 2 | 22,0 | 20,3 | 12,13 | 6,48 | 70,3 | 69,1 | 1452 |

### ReStory Playtest

| Condição | Rodada | FPS médio | 1% low | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Quadros |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Menu fechado | 1 | 60,0 | 58,3 | 7,62 | 3,90 | 59,5 | 56,6 | 11035 |
| Menu fechado | 2 | 60,0 | 58,4 | 7,34 | 3,74 | 58,2 | 56,4 | 11189 |
| Menu aberto, opaco | 1 | 60,0 | 58,8 | 7,40 | 3,80 | 58,4 | 56,6 | 3977 |
| Menu aberto, opaco | 2 | 60,0 | 58,8 | 7,26 | 3,77 | 58,2 | 56,5 | 3973 |
| Menu aberto, vidro | 1 | 60,0 | 58,6 | 7,41 | 3,80 | 58,3 | 56,5 | 3970 |
| Menu aberto, vidro | 2 | 60,0 | 55,9 | 7,30 | 3,78 | 58,2 | 56,5 | 3983 |

### RetroArch (atalho não-Steam)

| Condição | Rodada | FPS médio | 1% low | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Quadros |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Menu fechado | 1 | 60,0 | 59,6 | 5,73 | 2,64 | 55,2 | 53,9 | 11151 |
| Menu fechado | 2 | 60,0 | 59,6 | 5,69 | 2,63 | 55,1 | 53,7 | 11058 |
| Menu aberto, opaco | 1 | 60,0 | 59,6 | 5,90 | 2,64 | 55,3 | 53,8 | 3990 |
| Menu aberto, opaco | 2 | 60,0 | 59,6 | 5,68 | 2,63 | 55,2 | 53,7 | 3970 |
| Menu aberto, vidro | 1 | 60,0 | 59,6 | 5,83 | 2,66 | 55,4 | 53,8 | 4029 |
| Menu aberto, vidro | 2 | 60,0 | 59,6 | 5,77 | 2,66 | 55,2 | 53,8 | 4003 |

### Alone in the Dark (extra, travado a 30 FPS)

| Condição | Rodada | FPS médio | 1% low | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Quadros |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Menu fechado | 1 | 30,0 | 21,2 | n/d | 4,59 | 58,2 | 55,6 | 5578 |
| Menu fechado | 2 | 30,0 | 21,1 | 8,58 | 4,61 | 59,6 | 56,8 | 5596 |
| Menu aberto, opaco | 1 | 30,0 | 21,7 | 9,15 | 4,57 | 59,6 | 56,6 | 1971 |
| Menu aberto, opaco | 2 | 30,0 | 22,1 | 8,62 | 4,50 | 59,9 | 56,9 | 1986 |
| Menu aberto, vidro | 1 | 30,0 | 21,7 | 8,64 | 4,57 | 59,7 | 56,8 | 1983 |
| Menu aberto, vidro | 2 | 30,0 | 21,4 | 8,62 | 4,54 | 59,8 | 56,9 | 1974 |

## Vidro contra opaco com o menu aberto em jogo

| Jogo | FPS opaco | FPS vidro | Diferença | 1% low opaco | 1% low vidro | W opaco | W vidro | Diferença (W) | Diferença na APU (W) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Solasta II (VSync duplo, 22 FPS) | 22,0 | 22,0 | -0,0% | 20,3 | 20,3 | 12,12 | 12,09 | -0,03 | 0,06 |
| ReStory Playtest | 60,0 | 60,0 | -0,0% | 58,8 | 57,2 | 7,33 | 7,36 | 0,02 | -0,00 |
| RetroArch (atalho não-Steam) | 60,0 | 60,0 | 0,0% | 59,6 | 59,6 | 5,79 | 5,80 | 0,01 | 0,03 |
| Alone in the Dark (extra, travado a 30 FPS) | 30,0 | 30,0 | 0,0% | 21,9 | 21,6 | 8,89 | 8,63 | -0,26 | 0,02 |

## Conclusão

**Home: aprovado.** Vidro não tem custo mensurável em repouso. Um bloco de vidro teve só 27 amostras no mesmo brilho, então a referência mais forte é a APU, que não depende da tela.

**Menu aberto em jogo: nenhuma queda de FPS medida nos quatro títulos.** A maior diferença de APU foi 0,06 W, no Solasta II. O ReStory teve um bloco de vidro com 1% low de 55,9 contra 58,6 da repetição, sem diferença no FPS médio, o que não basta para atribuir ao vidro. O resultado é coerente com o que o Steam já faz: ele desfoca a tela de baixo com qualquer patch.

**Isso não justifica o opaco como padrão por FPS.** O critério pedia registrar uma queda que sustentasse o opaco, e ela não apareceu. O limite é o jogo pesado, preso a 22 FPS: o teste não exclui um custo pequeno em jogo sem VSync. O opaco em jogo continua porque é o comportamento pedido, não porque a medição o exija.

**O que não foi medido:** gameplay real, Deck OLED, e o menu visto na tela durante a rodada.
