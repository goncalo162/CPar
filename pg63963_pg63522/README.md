# Setup

```bash
cp .env.example .env
```

Altera os valores do `.env` para os do teu computador:

| Variável          | Descrição                                                                 |
|-------------------|---------------------------------------------------------------------------|
| `KEY`             | Caminho da chave SSH privada (ex.: `$HOME/.ssh/id_ed25519`)               |
| `USER_HOST`       | `utilizador@servidor` do cluster                                          |
| `PART_REMOTE_DIR` | Caminho do projeto no cluster, relativo a `/projects/F202500010HPCVLABUMINHO` |

O diretório remoto completo é `REMOTE_DIR = /projects/F202500010HPCVLABUMINHO/$PART_REMOTE_DIR`.

Requisitos locais: `bash`, `ssh`/`scp` (OpenSSH) e `gnuplot` >= 5.2(opcional para gerar os gráficos).

# Scripts

Os scripts que falam com o cluster usam uma única ligação SSH partilhada: a
password/passphrase é pedida uma só vez e a ligação fica aberta 2h desde o
último uso (`CM_PERSIST=30m` para mudar). Todos partilham-na.

## `scripts/run_benchmark.sh [--u]`

Corre o benchmark completo no cluster e traz os resultados.

```bash
scripts/run_benchmark.sh        # corre o benchmark
scripts/run_benchmark.sh --u    # envia primeiro os ficheiros (scripts/upload_files.sh)
```

1. (`--u`) Envia os ficheiros de `scripts/upload_files.sh` para o cluster.
2. Submete `scripts/benchmark.sh` com `sbatch`.
3. Espera pelo fim do job (verifica a cada 60 s).
4. Copia `benchmark_<JOBID>/` para a máquina local.
5. Gera os gráficos com `scripts/plot_result.gp` em `plots/`.

Se o job falhar (`FAILED`, `TIMEOUT`, `CANCELLED`), copia só os logs
`out.o<JOBID>` e `err.e<JOBID>` para inspeção.

## `scripts/run_single.sh [--u]`

Corre **uma** run do `md` num job `sbatch` de 2 minutos (compila com
`make md` e corre `make runTest`) e mostra o resultado no terminal.

```bash
scripts/run_single.sh              # 48 threads
scripts/run_single.sh --u          # envia primeiro os ficheiros
THREADS=16 scripts/run_single.sh   # outro nº de threads
```

Guarda os logs do job, `cp_average.txt` e `cp_output.txt` em `single_<JOBID>/`.
O limite de tempo, a conta e a partição estão no início do script.

## `scripts/upload_files.sh`

Envia ficheiros do projeto para `REMOTE_DIR` no cluster. É o que o `--u` dos
scripts anteriores chama.

```bash
scripts/upload_files.sh                    # envia src/MD.cpp, Makefile e scripts/benchmark.sh
scripts/upload_files.sh src/MD.cpp Makefile # envia só estes
scripts/upload_files.sh --close            # fecha a ligação SSH partilhada
```

Cada ficheiro pode ser `local` ou `local:remoto` (caminhos relativos à raiz do
projeto e a `REMOTE_DIR`). A lista por defeito está em `DEFAULT_FILES`, no
início do script.

## `scripts/benchmark.sh`

Corre **no cluster** (submetido pelo `run_benchmark.sh`). Compila com
`make md`, executa o `md` para vários números de threads com `perf stat`
(o tempo é o `duration_time` do perf), valida os resultados contra
`reference.csv` e `reference_full.txt` e escreve `benchmark_<JOBID>/results.csv`
(médias) e `raw_results.csv`.

```bash
sbatch scripts/benchmark.sh [repetições]   # por defeito: 3
```

## `scripts/plot_result.gp`

Gera os gráficos a partir de um `results.csv`.

```bash
gnuplot -e "csvfile='benchmark_<JOBID>/results.csv'; outdir='plots'" scripts/plot_result.gp
```

- `plots/*.png` e `plots/charts.pdf`: gráficos da run atual.
- `plots/cmp_*.png` e `plots/charts_compare.pdf`: run atual vs `compare/best_results.csv`.
- Se algum `seconds elapsed` da run atual for inferior a todos os de
  `compare/best_results.csv`, imprime `NOVO MELHOR RESULTADO`, pede o nome da
  run antiga, guarda-a em `compare/best_history/<nome>.csv` e passa a run atual
  a `compare/best_results.csv`.