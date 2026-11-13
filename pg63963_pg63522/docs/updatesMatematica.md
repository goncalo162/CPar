# Potential fundido no computeAccelerations

## Problema encontrado:

O Potential() é um segundo ciclo O(N²) (12.5 M pares por passo) que repete o trabalho do computeAccelerations():
os mesmos dx, dy, dz, o mesmo r2 e a mesma 1/r2 (frecpe + Newton), sobre as mesmas posições. As posições não mudam
entre os dois no ciclo principal. Além disso, é mais uma região paralela por passo, com fork, barreira e redução.

## Solução proposta:

Calcular a energia de cada par dentro do ciclo das forças, reutilizando o inv2 que já existe.
O Potential() passa só a devolver o valor guardado. Como o ciclo das forças percorre todos os pares i ≠ j (cada par 2 vezes)
, a soma já é o “2 × Pot” do original, e basta multiplicar por 4ε. Para j == i, inv2 = 0, logo a contribuição é 0.

|                  | Tempo total     | CPI    | #I      | Ciclos  | L1 miss | L2 miss | Ops FP  | % ocupação de cores |
| ---------------- | --------------- | ------ | ------- | ------- | ------- | ------- | ------- | ------------------- |
| Antes do update  | 0.468 s         | 1.174  | 36.22 G | 42.52 G | 650.1 M | n/d     | 49.23 G | 94.6 %              |
| Depois do update | 0.408 s         | 1.289  | 28.46 G | 36.68 G | 486.5 M | n/d     | 42.97 G | 93.6 %              |
| Ganho            | −12.8 % (1.15×) | +9.8 % | −21.4 % | −13.7 % | −25.2 % | n/d     | −12.7 % | −1.0 pp             |

# Dependências RAW

## Problema encontrado:

Depois das fusões, o computeAccelerations ocupa ~90% do tempo, mas corre muito abaixo do que o A64FX consegue: IPC de 0.78
(36.7 G ciclos para 28.5 G instruções). A memória não é o problema (miss rate da L2 de 0.22% no `perf annotate` os loads têm só ~1.9% das amostras cada)

O problema são as dependências RAW dentro de cada par (i, j). O cálculo de um par é uma cadeia em que cada instrução precisa do resultado da anterior:

`load → dx,dy,dz → r2 → 1/r2 (frecpe + 2 Newton do GCC) → inv2 (o nosso Newton) → inv4 → inv8 → inv14 → f → fx += dx·f`

São ~16 operações em série, a ~9 ciclos de latência cada (FMA no A64FX), ≈ 150 ciclos por par. Os pares j são independentes entre si,
mas com ~37 instruções por iteração a janela fora-de-ordem do A64FX só consegue ter ~3–4 iterações em curso ao mesmo tempo.
Cada iteração vetorial (8 pares) demora assim ~50 ciclos. No `perf annotate`, ~84% das amostras do kernel estão nas 7 instruções
da cauda da cadeia (`inv4 → … → ×inv8 → fmla`, com 17.0% e 17.4% nas duas últimas): o CPU está parado à espera do passo anterior.

A dependência dentro de um par é verdadeira (vem da própria matemática) e não se pode eliminar. O que se pode fazer é
(1) encurtar a cadeia
(2) dar ao CPU mais trabalho independente enquanto espera.

## Solução proposta:

### 1. Potências em árvore (encurtar a cadeia)

Em vez de `inv4 → inv8 → inv14 → f` em série, as potências calculam-se em ramos independentes a partir do `inv2`, e são partilhadas entre a força e a energia:

- nível 1: `2·inv2` e `inv4`
- nível 2: `inv6 = inv4·inv2`, `inv8 = inv4²` e `s = 2·inv2·inv4 − 1`
- nível 3: `f = inv8·s = 2/r¹⁴ − 1/r⁸` e `u = inv6·(inv6 − 1) = 1/r¹² − 1/r⁶`

O fator 24 sai do ciclo e aplica-se uma vez por partícula (`Σ dx·24·f = 24·Σ dx·f`).
A energia usa σ = ε = 1, que as forças originais já assumiam.
A cadeia depois do `inv2` passa de 5 para 4 passos (força e energia) e o ciclo perde 4 instruções FP.

### 2. Fissão do ciclo j por blocos (pipelining manual)

O ciclo j é partido em blocos de `BLK` elementos, e cada bloco passa por 3 ciclos curtos:

1. `r2` → guardado em `r2v[]`
2. `1/r2` + Newton → guardado em `inv2v[]`
3. potências em árvore + acumulação de `fx, fy, fz, ui`

Cada ciclo tem só 14–23 instruções e uma cadeia de 4–7 passos, por isso a janela do CPU consegue ter muitas mais iterações independentes em curso.
A latência de cada par continua lá, mas fica escondida por outros pares.
Os temporários (2 × BLK doubles) são privados de cada thread (declarados dentro da região paralela),
por isso não há data races, e com BLK = 512 ocupam 8 KB (cabem na L1 de 64 KB).

Tentou-se também o software pipelining automático do GCC (`-fmodulo-sched`).
O GCC 15 consegue aplicá-lo ao ciclo, mas só sobrepõe 2 iterações (`SMS succeeded 6 2`) e o ganho foi de apenas 1.8%, o que justifica fazê-lo à mão.
Desenrolar o ciclo (`--param aarch64-vect-unroll-limit`, `#pragma GCC unroll`) não teve efeito, e múltiplos acumuladores não atacam o problema

## Tabela comparativa

48 threads, `OMP_PROC_BIND=close`, `OMP_PLACES=cores`, BLK = 512. Validado com `valida_casas`.

|                                 | Tempo total | CPI   | #I       | Ciclos   | L1 miss | L2 miss | Ops FP   | % ocupação de cores |
| ------------------------------- | ----------- | ----- | -------- | -------- | ------- | ------- | -------- | ------------------- |
| Fusão                           | 0.408 s     | 1.289 | 28.46 MM | 36.68 MM | 486.5 M | n/d     | 42.97 MM | 93.6 %              |
| Uso de flags (`-fmodulo-sched`) | 0.401 s     | 1.232 | 29.28 MM | 36.06 MM | 486.1 M | n/d     | 42.96 MM | 93.7 %              |
| Árvore + Pipelining             | 0.308 s     | 0.686 | 39.44 MM | 27.05 MM | 487.3 M | n/d     | 43.09 MM | 91.4 %              |
| Speedup (Fusão → A+P)           | 1.32×       | 1.88× | 0.72×    | 1.36×    | 0.998×  | n/d     | 0.997×   | −2.2 pp             |

Executam-se mais 39% de instruções (loads/stores dos temporários e overhead dos 3 ciclos), mas o IPC passa de 0.78 para 1.46: o mesmo trabalho FP (43 G) faz-se em menos 26% de ciclos.
As L1 loads quase triplicam sem aumento de misses, porque os temporários vivem na L1.
Foi escolhido uso de blocos com 512 pois ocupa 20 KB dos 64 KB da L1. Ganhos de subir não sao estavaies devido ao uso da L1.
Com o kernel mais rápido, a sincronização ganha peso (barreiras de ~7% para 11.3% do tempo), como prevê a lei de Amdahl.
