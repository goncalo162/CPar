# Analise

## Analise de funções

| Função               | Complexiade    | Iters    | Paralizar  | % tempo | obs                                         |
| -------------------- | -------------- | -------- | ---------- | ------- | ------------------------------------------- |
| initialize           | N              | 5000     | Possivel   | .       | É possivel mas depende da % tempo           |
| initializeVelocities | 3N             | 15000    | N Possivel | .       | Usa rand e é perigoso                       |
| gaussdist            | 3x3N= 9N       | 45000    | N Possivel | .       | Usa rand e é perigoso                       |
| computeAccelerations | T x N^2        | 5MM      | Possivel   | 66,63%  | Paralizar dois ciclos + SIMD                |
| VelocityVerlet       | T x (2N + N^2) | 2M + 5MM | Possivel   | 0,01%   | Paralizar dois ciclos + SIMD                |
| MeanSquaredVelocity  | T x N          | 1M       | Possivel   | .       | Paralizar com Red mas ver se compensa       |
| Kinetic              | T x N          | 1M       | Possivel   | .       | Paralizar com Red mas ver se compensa       |
| Potential            | T x (N^2/2)    | 2.5MM    | Possivel   | 32,94%  | Paralizar dois ciclos + SIMD(cuidado carga) |

### computeAccelerations

Aqui acho que ha um possivel aproveitamento. Vamos diminuir ciclos com + contas
Vai ser preciso medir antes de depois do update para saver se vale a pena ou nao

### Potencial

Aqui é unico sitio que temos de ter atençao ao balanceamento de cargas pois não e tudo igual
Ciclo percorre cada atomo de forma unica logo com static podemos estar a desbalancear muito a carga

### MeanSquaredVelocity e Kinetic

Apesar de estar paralelizado e preciso ver se compensa o overhead de paralizar visto que sao apenas 5000 ops de cada vez

### initialize

É possivel ganhar uns usec aqui. E preciso tentar e ver se ha ganho ou não. Visto que é da sec de init e apenas é 5000 ops
deixar para segundo plano e so se começar a pesar no futuro passar por aqui

# Parelização

## Primeira Parelização

### Apos primeira Parelização

| Função               | Paralizar(Estado) | % tempo | % tempo (48t) |
| -------------------- | ----------------- | ------- | ------------- |
| initialize           | -                 | .       | Resto         |
| initializeVelocities | -                 | .       | Resto         |
| gaussdist            | -                 | .       | Resto         |
| computeAccelerations | Feito             | 66,63%  | 64,4          |
| VelocityVerlet       | Feito             | 0,01%   | Resto         |
| MeanSquaredVelocity  | Feito             | .       | Resto         |
| Kinetic              | Feito             | .       | Resto         |
| Potential            | Feito             | 32,94%  | 27,9          |
| Barreiras            | -                 | -       | 6,5           |
| Locks                | -                 | -       | 0,9           |

Resto = 0.05%

## Segundap Parelização

O metodo aqui vai ser um pouco diferente. Vou aplicar pequenas alterações e medir o desempenho relativo
a ultima versão parelizada(assumir sempre melhor versão até ao momento)

### Melhorar parelização da função Potential

Aqui vou estudar qual a melhor maneira de dividir as carga de maneira uniforme por todas as threads.
Objetivo: Diminuir tempo em Barreiras e melhor tempo total da função Potential
Métricas: Avaliar Barreiras, tempo total de exe, e carga da função Potential

Teste com (static, 1)
Vantagem: Facil e legivel
Desvantagem: Continua a desiquilbrar mas com N=5000 pode ser desprezavel

| Threads | % barreiras | % Potential | Tempo (s) |
| ------- | ----------- | ----------- | --------- |
| 8       | 0,75        | 29,97       | 14,52     |
| 16      | 1,68        | 29,71       | 7,42      |
| 48      | 6,51        | 27,86       | 2,63      |
| 96      | 0,09        | 30,18       | 3,21      |
| 128     | 0,13        | 30,17       | 3,42      |
| 144     | 0,12        | 30,20       | 3,46      |

| Threads | % barreiras | % Potential | Tempo (s) |
| ------- | ----------- | ----------- | --------- |
| 8       | 0,32        | 30,01       | 11,49     |
| 16      | 0,79        | 29,96       | 5,81      |
| 48      | 4,15        | 28,59       | 2,03      |
| 96      | 0,10        | 30,18       | 2,62      |
| 128     | 0,12        | 30,15       | 3,05      |
| 144     | 0,14        | 30,58       | 2,91      |

Analise: Com static, 48 threads só tinham ~38 cores ocupados em média, porque as outras
esperavam pela thread 0. Com static,1 ficam 47,3 de 48

Teste com emparelhar linhas (Linha i + linha N-i)
Vantagem: Balanceamento perfeito
Desvantagem: Legebilidade

| Threads | % carga Barreiras | % carga Potential | Tempo exec (s) |
| ------: | ----------------: | ----------------: | -------------: |
|       8 |              0,45 |             30,09 |          11,50 |
|      16 |              0,83 |             29,95 |           5,82 |
|      48 |              4,23 |             28,60 |           2,07 |
|      96 |              0,10 |             30,21 |           2,61 |
|     128 |              0,12 |             30,27 |           3,06 |
|     144 |              0,14 |             30,48 |           2,92 |

Analise: o emparelhado executa mais instruções (131 MM contra 122 MM) e
mais branches (10,5 MM vs 7,4 MM). Cada iteração tem agora dois ciclos simd

### Utilização de SIMD

Tentar aplicar a todas as as funções possiveis tecnicas de SIMD de forma legivel
Obejtivo: Veotrizar calculos
Métricas: Avaliar tempo total de exe e carga de cada uma das funções

#### MeanSquaredVelocity e Kinetic (reduções sobre N)

Importancia: 2
Analise: com 48 threads, cada uma faz só uns 104 elementos, por isso o ganho real é desprezável.

#### VelocityVerlet

Importancia: 1
Analise:
1 cilco -> é O(N) por isso o ganho no tempo total é quase nulo. O -O3 já o deve vetorizar sozinho.
2 ciclo -> as colisões com as paredes são raras, e a versão vetorial avalia sempre os dois caminhos.
Pode ficar igual ou até mais lento. O(N) por isso não compensa perder tempo para ja

#### computeAccelerations

Importancia: 5
Analise:
1 cilco -> Por sis so SIMD não mas explorar -O3 -funroll-loops ou loop unrolling a mão
2 ciclo -> acesso contíguo a rx/ry/rz[j] , nenhuma escrita partilhada super valido e local onde passa mais tempo

#### Potential

Importancia: 5
Analise:
1 cilco -> Por si só SIMD não (igual ao computeAccelerations), já está dividido por threads (static,1)
2 ciclo -> acesso contíguo a rx/ry/rz[j], nenhuma escrita partilhada, nem precisa do (i==j) porque
j começa em i+1.
Desvantagens: resto em cada linha (N-1-i nem sempre múltiplo de 8), últimas linhas curtas,
início desalinhado — tudo pequeno (~0,3% desperdício), SVE trata o resto com máscara

#### notas sobre SIMD

(base) miguelsantos@Mac pg63963_pg63522 % ssh deucalion "cd /projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522 && srun -A f202500010hpcvlabuminhoa -p normal-arm -t 5 -N1 -n1 -c 1 bash -c 'ml GCC >/dev/null 2>&1
for F in \"\" \"-mcpu=a64fx\" \"-mcpu=a64fx -msve-vector-bits=512\"; do
echo \"===== flags: \$F\"
gcc -x c -O3 -ffast-math -fopenmp \$F -fopt-info-vec src/MD.cpp -lm -o /dev/null 2>&1 | grep -E \"MD.cpp:[0-9]+\"
done'"
srun: job 2223327 queued and waiting for resources
srun: job 2223327 has been allocated resources
===== flags:
src/MD.cpp:264:25: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:278:37: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:332:9: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:335:38: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:358:9: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:361:38: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:358:9: optimized: basic block part vectorized using 16 byte vectors
src/MD.cpp:358:9: optimized: basic block part vectorized using 16 byte vectors
src/MD.cpp:358:9: optimized: basic block part vectorized using 16 byte vectors
src/MD.cpp:398:11: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:261:9: optimized: basic block part vectorized using 16 byte vectors
src/MD.cpp:483:23: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:473:23: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:242:31: optimized: loop vectorized using 8 byte vectors
===== flags: -mcpu=a64fx
src/MD.cpp:264:25: optimized: loop vectorized using variable length vectors
src/MD.cpp:261:9: optimized: basic block part vectorized using 16 byte vectors
src/MD.cpp:278:37: optimized: loop vectorized using variable length vectors
src/MD.cpp:332:9: optimized: loop vectorized using variable length vectors
src/MD.cpp:335:38: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:358:9: optimized: loop vectorized using variable length vectors
src/MD.cpp:361:38: optimized: loop vectorized using 16 byte vectors
src/MD.cpp:398:11: optimized: loop vectorized using variable length vectors
src/MD.cpp:483:23: optimized: loop vectorized using variable length vectors
src/MD.cpp:473:23: optimized: loop vectorized using variable length vectors
src/MD.cpp:242:31: optimized: loop vectorized using variable length vectors
===== flags: -mcpu=a64fx -msve-vector-bits=512
src/MD.cpp:264:25: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:261:9: optimized: basic block part vectorized using 16 byte vectors
src/MD.cpp:278:37: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:332:9: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:335:38: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:358:9: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:361:38: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:398:11: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:483:23: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:473:23: optimized: loop vectorized using 64 byte vectors
src/MD.cpp:242:31: optimized: loop vectorized using 8 byte vectors
(base) miguelsantos@Mac pg63963_pg63522 %

#### Resultados

Base PB

| Threads | % computeAccelerations | % Potential | #(IMM) | CPI  | Tempo (s) |
| ------- | ---------------------- | ----------- | ------ | ---- | --------- |
| 8       | 69,63                  | 30,01       | 109,5  | 1,67 | 11,49     |
| 16      | 69,14                  | 29,96       | 113,3  | 1,63 | 5,81      |
| 48      | 66,08                  | 28,59       | 121,9  | 1,57 | 2,03      |
| 96      | 69,56                  | 30,18       | 109,4  | 1,72 | 2,62      |
| 128     | 69,51                  | 30,15       | 110,3  | 1,73 | 3,05      |
| 144     | 69,06                  | 30,58       | 110,5  | 1,73 | 2,91      |

Com SIMD aplicado a computeAccelerations e Potential

| Threads | % computeAccelerations | % Potential | #(IMM) | CPI  | Tempo (s) |
| ------- | ---------------------- | ----------- | ------ | ---- | --------- |
| 8       | 66,56                  | 33,01       | 34,8   | 4,24 | 9,25      |
| 16      | 66,16                  | 32,81       | 40,9   | 3,67 | 4,75      |
| 48      | 61,68                  | 30,77       | 54,6   | 2,91 | 1,69      |
| 96      | 66,56                  | 33,12       | 35,1   | 4,35 | 2,25      |
| 128     | 66,26                  | 33,32       | 35,9   | 4,33 | 2,66      |
| 144     | 65,74                  | 33,80       | 36,1   | 4,32 | 2,49      |

#### uso de nova flag -msve-vector-bits=512

Explicação: Depois do SVE, o gargalo dos dois kernels passou a ser a divisão 1.0 / r2,
feita uma vez por cada par (~7,5MMde pares por execução). No A64FX a
divisão SVE (fdiv) é muito lenta e não é pipelined.

Uso: A flag é por ficheiro e aplicada a tudo o que lá está. Aplicada ao MD.cpp
inteiro, tornava aproximadas também as divisões do cálculo da pressão, e a
validação falhava no P. Por isso os dois kernels passaram para `src/forces.c`
(com `src/md.h` para as globais partilhadas), e só esse ficheiro é compilado com a
flag (`KERNEL_FLAGS` no Makefile). O resto do programa mantém divisões exatas.

Mudanças:
`src/forces.c`: `computeAccelerations` e `Potential`, com a correção de Newton

PB

| Threads | % computeAccelerations | % Potential | #(IMM) | CPI  | Tempo (s) |
| ------- | ---------------------- | ----------- | ------ | ---- | --------- |
| 8       | 66,56                  | 33,01       | 34,8   | 4,24 | 9,25      |
| 16      | 66,16                  | 32,81       | 40,9   | 3,67 | 4,75      |
| 48      | 61,68                  | 30,77       | 54,6   | 2,91 | 1,69      |
| 96      | 66,56                  | 33,12       | 35,1   | 4,35 | 2,25      |
| 128     | 66,26                  | 33,32       | 35,9   | 4,33 | 2,66      |
| 144     | 65,74                  | 33,80       | 36,1   | 4,32 | 2,49      |

| Threads | % computeAccelerations | % Potential | #(IMM) | CPI  | Tempo (s) |
| ------- | ---------------------- | ----------- | ------ | ---- | --------- |
| 8       | 67,02                  | 31,51       | 40,5   | 1,13 | 2,88      |
| 16      | 65,57                  | 30,87       | 42,1   | 1,10 | 1,47      |
| 48      | 57,74                  | 27,47       | 48,9   | 1,08 | 0,575     |
| 96      | 67,29                  | 31,72       | 41,2   | 1,24 | 1,14      |
| 128     | 68,79                  | 29,83       | 41,9   | 1,27 | 1,40      |
| 144     | 69,36                  | 29,15       | 42,2   | 1,28 | 1,43      |

| Função                                            | % do tempo |
| ------------------------------------------------- | ---------- |
| computeAccelerations                              | 57,7       |
| Potential                                         | 27,5       |
| Sincronização OpenMP(barreiras)                   | 10,5       |
| Sincronização OpenMP(locks/atómicos das reduções) | 2,1        |
| Kinetic                                           | 1,8        |
| VelocityVerlet + MeanSquaredVelocity              | 0,3        |

#### Analise perf annotate

Analise:Com o perf annotate ao computeAccelerations (48 threads) vimos o assembly do ciclo j
e a % de amostras por instrução. O ciclo estava bem vetorizado
(SVE 512 bits, registos z, desenrolado 2×, 16 pares por iteração) e já sem fdiv
(frecpe + frecps + a nossa iteração de Newton pesam < 10%).
Mas os acumuladores fx, fy, fz estavam na stack e não em registos: em cada iteração havia 6 ld1d e 6 st1d sobre sp + ….
Isto cria uma dependência através da memória: o load de uma iteração espera
pelo store da anterior (store-to-load forwarding, lento para vetores SVE de 64 B).

Sugestao: ar o #pragma omp simd reduction(...) dos ciclos j dos dois kernels
e deixar o auto-vetorizador do GCC tratar da redução
(-O3 + -ffast-math permitem reordenar as somas), mantendo os acumuladores em registos.

PB

| Threads | % computeAccelerations | % Potential | #(IMM) | CPI  | Tempo (s) |
| ------- | ---------------------- | ----------- | ------ | ---- | --------- |
| 8       | 67,02                  | 31,51       | 40,5   | 1,13 | 2,88      |
| 16      | 65,57                  | 30,87       | 42,1   | 1,10 | 1,47      |
| 48      | 57,74                  | 27,47       | 48,9   | 1,08 | 0,575     |
| 96      | 67,29                  | 31,72       | 41,2   | 1,24 | 1,14      |
| 128     | 68,79                  | 29,83       | 41,9   | 1,27 | 1,40      |
| 144     | 69,36                  | 29,15       | 42,2   | 1,28 | 1,43      |

Novos Resultados

| Threads | % computeAcc | % Potential | #(IMM) | CPI  | Tempo (s) |
| ------- | ------------ | ----------- | ------ | ---- | --------- |
| 8       | 70,18        | 28,86       | 29,2   | 1,22 | 2,25      |
| 16      | 68,39        | 28,37       | 30,5   | 1,19 | 1,16      |
| 48      | 59,49        | 24,30       | 36,2   | 1,17 | 0,490     |
| 96      | 69,66        | 28,84       | 30,6   | 1,36 | 1,04      |
| 128     | 70,98        | 27,33       | 31,3   | 1,38 | 1,28      |
| 144     | 70,37        | 27,44       | 31,7   | 1,40 | 1,30      |

#### Sincronização OpenMP

| Parte                                              | % do tempo |
| -------------------------------------------------- | ---------- |
| computeAccelerations                               | 59,5       |
| Potential                                          | 24,3       |
| Sincronização OpenMP (barreiras)                   | 10,9       |
| Sincronização OpenMP (locks/atómicos das reduções) | 2,7        |
| Kinetic                                            | 2,1        |
| VelocityVerlet + MeanSquaredVelocity               | 0,3        |
| Gestão de threads (team_start, thread_start, …)    | 0,2        |
| Resto (parte em série, I/O)                        | ~0         |

| Região                         | T1 (s)  | TN (s) | % de TN | Speedup | Efic. | Perda (s) |
| ------------------------------ | ------- | ------ | ------- | ------- | ----- | --------- |
| VelocityVerlet (2 ciclos O(N)) | 0.0104  | 0.0107 | 2.5%    | 1.0x    | 2%    | 0.0105    |
| computeAccelerations           | 12.3909 | 0.2691 | 61.4%   | 46.0x   | 96%   | 0.0110    |
| MeanSquaredVelocity            | 0.0014  | 0.0198 | 4.5%    | 0.1x    | 0%    | 0.0198    |
| Kinetic                        | 0.0013  | 0.0181 | 4.1%    | 0.1x    | 0%    | 0.0181    |
| Potential                      | 5.1496  | 0.1178 | 26.9%   | 43.7x   | 91%   | 0.0105    |
| Resto (série, I/O)             | 0.0032  | 0.0025 | 0.6%    | 1.3x    | 3%    | 0.0024    |
| TOTAL (ciclo principal)        | 17.5568 | 0.4380 | 100.0%  | 40.1x   | 84%   | 0.0722    |
