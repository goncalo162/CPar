#!/usr/bin/env bash
# Testa schedule(dynamic, CHUNK) de 1 a 48, com 48 threads e 10 runs por valor.
# Executar no Mac (com alias SSH "deucalion" configurado):
#   ./testa_dynamic.sh                  # chunks 1..48, 10 runs
#   NRUNS=5 ./testa_dynamic.sh          # chunks 1..48, 5 runs
#   ./testa_dynamic.sh 10 20            # apenas chunks 10..20
#   WALLTIME=180 ./testa_dynamic.sh     # reserva até 180 minutos no Slurm
# Saída: resultados/dynamic_YYYYMMDD_HHMMSS.txt (no Mac)
# Usa src/newton.c, src/MD.cpp, src/md.h e Makefile já presentes no Deucalion.

set -euo pipefail

FIRST="${1:-1}"
LAST="${2:-48}"
NRUNS="${NRUNS:-10}"
WALLTIME="${WALLTIME:-120}"  # minutos de reserva Slurm; ajustar se necessário

REMOTE="deucalion"
DIR="/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522"
ACCOUNT="f202500010hpcvlabuminhoa"
EVENTS="task-clock,cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,br_pred,br_mis_pred,fp_dp_fixed_ops_spec,fp_dp_scale_ops_spec"

# Impede valores inválidos nos parâmetros passados para o comando remoto.
for value in "$FIRST" "$LAST" "$NRUNS" "$WALLTIME"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "Erro: são esperados inteiros positivos." >&2; exit 1; }
done
if (( FIRST < 1 || FIRST > LAST || LAST > 48 || NRUNS < 1 || WALLTIME < 1 )); then
    echo "Erro: usar 1 <= PRIMEIRO <= ULTIMO <= 48, NRUNS >= 1, WALLTIME >= 1." >&2
    exit 1
fi

mkdir -p resultados
OUT="resultados/dynamic_$(date +%Y%m%d_%H%M%S).txt"
printf 'A testar dynamic(%s..%s), 48 threads, %s runs por valor.\n' "$FIRST" "$LAST" "$NRUNS"
echo "A guardar os resultados em: $OUT"

ssh "$REMOTE" "cd '$DIR' && FIRST='$FIRST' LAST='$LAST' NRUNS='$NRUNS' EVENTS='$EVENTS' \
    srun -A '$ACCOUNT' -p normal-arm -t '$WALLTIME' -N1 -n1 -c 48 bash -s" <<'REMOTO' | tee "$OUT"
set -euo pipefail
export LC_ALL=C
ml GCC >/dev/null 2>&1
export OMP_NUM_THREADS=48
export OMP_DYNAMIC=FALSE
export OMP_PROC_BIND=close
export OMP_PLACES=cores
export OMP_WAIT_POLICY=active

for f in Makefile src/MD.cpp src/newton.c src/md.h inputdata.txt; do
    if [ ! -f "$f" ]; then
        echo "ERRO: não existe $f no diretório remoto $(pwd)" >&2
        exit 1
    fi
done

# Exigir exatamente uma diretiva dinâmica com chunk numérico em src/newton.c.
PADRAO='^[[:space:]]*#pragma[[:space:]]+omp[[:space:]]+for[[:space:]]+schedule\(dynamic,[[:space:]]*[0-9]+[[:space:]]*\)'
OCORRENCIAS=$(grep -Ec "$PADRAO" src/newton.c || true)
if [ "$OCORRENCIAS" -ne 1 ]; then
    echo "ERRO: esperada 1 diretiva '#pragma omp for schedule(dynamic, N)' em src/newton.c; encontradas $OCORRENCIAS." >&2
    exit 1
fi

# Obter as mesmas flags do Makefile original (não modificar o Makefile).
CF=$(sed -n 's/^CFLAGS[[:space:]]*=[[:space:]]*//p' Makefile)
KF=$(sed -n 's/^KERNEL_FLAGS[[:space:]]*=[[:space:]]*//p' Makefile)
LF=$(sed -n 's/^LDFLAGS[[:space:]]*=[[:space:]]*//p' Makefile)
[ -n "$CF" ] || { echo "ERRO: CFLAGS em falta no Makefile." >&2; exit 1; }

# Diretório temporário isolado. O original src/newton.c nunca é alterado.
WORK=$(mktemp -d "./.bench_dynamic.XXXXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

printf '\n===== CONFIGURACAO =====\n'
printf 'Data: %s\n' "$(date)"
printf 'No: %s\n' "$(hostname)"
printf 'GCC: %s\n' "$(gcc --version | head -n 1)"
printf 'Threads: 48 | Runs por chunk: %s | Chunks: %s..%s\n' "$NRUNS" "$FIRST" "$LAST"
printf 'Fonte: src/newton.c | CFLAGS: %s | KERNEL_FLAGS: %s\n' "$CF" "$KF"
printf 'MD5 original: %s\n' "$(md5sum src/newton.c | awk '{print $1}')"

# MD.cpp não depende do valor do chunk: compilar uma vez.
# Intencionalmente expandimos as flags do Makefile em palavras.
# shellcheck disable=SC2086
gcc $CF -x c -c src/MD.cpp -o "$WORK/MD.o"

for K in $(seq "$FIRST" "$LAST"); do
    echo
    printf '===== schedule(dynamic, %d) =====\n' "$K"

    # Cria uma cópia com o valor de K na diretiva; preserva o original.
    sed -E "s/^([[:space:]]*#pragma[[:space:]]+omp[[:space:]]+for[[:space:]]+schedule)\(dynamic,[[:space:]]*[0-9]+[[:space:]]*\)/\1(dynamic, $K)/" \
        src/newton.c > "$WORK/newton.c"

    # -Isrc é necessário porque o .c temporário inclui "md.h".
    # shellcheck disable=SC2086
    gcc $CF $KF -Isrc -c "$WORK/newton.c" -o "$WORK/newton.o"
    # shellcheck disable=SC2086
    gcc $CF "$WORK/MD.o" "$WORK/newton.o" -lm $LF -o "$WORK/md"

    : > "$WORK/tempos.txt"
    for R in $(seq 1 "$NRUNS"); do
        # Preserva o método de medição de tempo do recolhe.sh: perf stat.
        if ! perf stat -e "$EVENTS" "$WORK/md" < inputdata.txt > /dev/null 2> "$WORK/perf.txt"; then
            echo "ERRO: falhou o perf stat para chunk=$K, run=$R." >&2
            cat "$WORK/perf.txt" >&2
            exit 1
        fi
        T=$(awk '/seconds time elapsed/ {print $1; exit}' "$WORK/perf.txt")
        if ! [[ "$T" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "ERRO: tempo invalido no perf para chunk=$K, run=$R: '$T'." >&2
            cat "$WORK/perf.txt" >&2
            exit 1
        fi
        printf '%s\n' "$T" >> "$WORK/tempos.txt"
        printf '  run %2d/%d: %s s\n' "$R" "$NRUNS" "$T"
    done

    # Estatísticas sobre todas as runs (mediana certa para NRUNS par e ímpar).
    sort -n "$WORK/tempos.txt" | awk -v k="$K" '
        { t[NR]=$1; soma+=$1 }
        END {
            n=NR
            if (n % 2 == 1) med=t[(n+1)/2]
            else med=(t[n/2]+t[n/2+1])/2
            printf "[%d] -> média: %.6f s | mediana: %.6f s | melhor: %.6f s | pior: %.6f s\n", \
                k, soma/n, med, t[1], t[n]
        }
    ' | tee -a "$WORK/resumo.txt"
done

printf '\n===== RESUMO FINAL: 48 THREADS, %s RUNS POR CHUNK =====\n' "$NRUNS"
cat "$WORK/resumo.txt"
printf '\n===== FIM =====\n'
REMOTO

echo "Resultados guardados em: $OUT"
