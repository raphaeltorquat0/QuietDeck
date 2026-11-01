# Quiet Glass: FPS e consumo

Relatório gerado por `scripts/perf/report.py` com dados do Deck real. Protocolo em `SMOKE_TEST.md`.

**Medição parcial.** Deck LCD, SteamOS 3.9.5, em 31/10/2026. Vale a home e Alone in the Dark. Faltam o jogo pesado no limite da GPU, o jogo leve e o atalho não-Steam, por isso a release segue bloqueada.

- Consumo é corrente vezes tensão da bateria, só descarregando. Na home contam só amostras no mesmo brilho, porque o sensor de luz ambiente muda o brilho sozinho e isso pesa mais que o medido.
- Sem controle no Deck, o jogo fica na tela de título.
- Com jogo aberto, a captura do gamescope só mostra o plano do jogo. O menu aberto foi conferido pelo Steam (`GetOpenSideMenu`) e pelo foco de entrada, sem prova visual.
- Substituição: RDR2 não abriu pela API do Steam. Alone in the Dark abriu, mas fica travado a 30 FPS no menu, então não mede queda de FPS perto do limite da GPU.
- Solasta II é o melhor candidato a pesado: 23,2 W no total e 14,3 W de APU com o menu fechado. O MangoHud não gravou, então não há FPS dele.

## Home parada

| Condição | Bloco | Consumo (W) | APU (W) | CPU (°C) | GPU (°C) | Ventoinha (rpm) | Amostras válidas |
|---|---|---:|---:|---:|---:|---:|---:|
| Vidro | 1 | 4,24 | 3,20 | 46,7 | 45,6 | 1501 | 39/306 |
| Vidro | 2 | 3,79 | 3,10 | 45,1 | 44,1 | 1502 | 306/306 |
| Opaco | 1 | 3,97 | 3,18 | 46,2 | 45,0 | 1498 | 306/306 |
| Opaco | 2 | 3,90 | 3,16 | 45,7 | 44,6 | 1498 | 306/306 |

**Vidro menos opaco: 0,08 W em média** (por bloco: 0,27, -0,11 W). Limite: 0,3 W. **Resultado: aprovado.** Só a APU, que não depende do brilho: -0,02 W.

## Jogos

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

| Jogo | FPS opaco | FPS vidro | Diferença | 1% low opaco | 1% low vidro | W opaco | W vidro | Diferença (W) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Alone in the Dark (extra, travado a 30 FPS) | 30,0 | 30,0 | 0,0% | 21,9 | 21,6 | 8,89 | 8,63 | -0,26 |

## Conclusão parcial

**Home: aprovado.** Vidro não tem custo mensurável em repouso. Um bloco de vidro teve só 27 amostras no mesmo brilho, então a referência mais forte é a APU, que não depende da tela.

**Menu aberto em jogo: ainda sem resposta.** Em Alone in the Dark, vidro e opaco deram o mesmo FPS, mas o jogo tem folga de GPU a 30 FPS travados. Isso não mostra que o vidro é de graça no limite da GPU, nem justifica sozinho o opaco como padrão.

**Pendente:** com a bateria carregada, descobrir por que o gamescope ficou com foco `769` e o MangoHud parou de gravar, e medir Solasta II, ReStory Playtest e o atalho não-Steam.
