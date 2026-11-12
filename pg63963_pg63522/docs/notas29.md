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
| Potential            | T x (N^2/2)    | 2.5MM    | N Possivel | 32,94%  | Paralizar dois ciclos + SIMD(cuidado carga) |

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
