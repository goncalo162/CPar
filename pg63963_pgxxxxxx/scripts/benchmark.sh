#!/bin/bash
#SBATCH -A f202500010hpcvlabuminhoa
#SBATCH -p normal-arm
#SBATCH -t 10:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=48
#SBATCH --output=out.o%j
#SBATCH --error=err.e%j

set -uo pipefail

# ============================================================
# Configuração
# ============================================================
REPEATS="${1:-3}"

THREADS=(1 2 4 8 16 32 48)
MAX_THREADS=48

INPUT="inputdata.txt"
EXECUTABLE="md"
REFERENCE="reference.csv"

# Grupo 1: FLOPs e tempo (para o eixo Y do roofline)
EVENTS_FLOPS="task-clock,cycles,instructions,fp_dp_fixed_ops_spec,fp_fma_spec"
# Grupo 2: memória e branches (para o eixo X do roofline)
EVENTS_MEM="br_pred,br_mis_pred,L1-dcache-loads,L1-dcache-load-misses,l2d_cache_refill"

BASE_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
cd "$BASE_DIR" || exit 1

JOB_ID="${SLURM_JOB_ID:-local}"
OUTDIR="$BASE_DIR/benchmark_${JOB_ID}"

mkdir -p "$OUTDIR/outputs" "$OUTDIR/perf"

RAW_RESULTS="$OUTDIR/raw_results.csv"
RESULTS="$OUTDIR/results.csv"
STATUS="$OUTDIR/status.txt"

export OMP_DYNAMIC=FALSE
export OMP_PROC_BIND=close
export OMP_PLACES=cores

# ============================================================
# Verificações
# ============================================================
if ! [[ "$REPEATS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Erro: o número de repetições deve ser um inteiro positivo."
    exit 1
fi
[[ -f "$INPUT" ]]     || { echo "Erro: não encontrei $INPUT"; exit 1; }
[[ -f "$REFERENCE" ]] || { echo "Erro: não encontrei $REFERENCE"; exit 1; }
command -v perf    >/dev/null || { echo "Erro: perf não disponível."; exit 1; }
command -v python3 >/dev/null || { echo "Erro: python3 não disponível."; exit 1; }

if [[ -f Makefile ]]; then
    make md || { echo "Erro de compilação."; exit 1; }
fi
[[ -x "./$EXECUTABLE" ]] || { echo "Erro: ./$EXECUTABLE não é executável."; exit 1; }

EXEC_ABS="$BASE_DIR/$EXECUTABLE"
INPUT_ABS="$BASE_DIR/$INPUT"
REFERENCE_ABS="$BASE_DIR/$REFERENCE"

echo "===== Hardware ====="
lscpu || true
echo
echo "Job: $JOB_ID"
echo "CPUs atribuídas: ${SLURM_CPUS_PER_TASK:-desconhecido}"
echo "Threads: ${THREADS[*]}"
echo "Repetições por configuração: $REPEATS"

# CSV bruto: todas as repetições (só perf; averages só validam)
echo "threads,repeat,kind,metric,value" > "$RAW_RESULTS"
# CSV final: médias
echo "threads,kind,metric,value,samples,stdev" > "$RESULTS"

echo "Benchmark iniciado." > "$STATUS"

# ============================================================
# Executa uma corrida do md com um grupo de eventos perf
# ============================================================
run_perf_group() {
    local group=$1 events=$2 run_dir=$3
    local perf_file="$OUTDIR/perf/perf_${group}_t${NTHREADS}_r${REP}.csv"

    mkdir -p "$run_dir"
    (
        cd "$run_dir" &&
        srun --cpu-bind=cores \
            perf stat -x, -o "$perf_file" \
            -e "$events" \
            -- env \
                OMP_NUM_THREADS="$NTHREADS" \
                OMP_DYNAMIC=FALSE \
                OMP_PROC_BIND=close \
                OMP_PLACES=cores \
                "$EXEC_ABS" \
                < "$INPUT_ABS" \
                > "$run_dir/stdout.txt" \
                2> "$run_dir/stderr.txt"
    )
}

# Regista os contadores de um ficheiro perf no CSV bruto
parse_perf_csv() {
    local perf_file=$1 expected=$2
    python3 - "$perf_file" "$NTHREADS" "$REP" "$RAW_RESULTS" "$expected" <<'PY'
import csv, math, sys

perf_file, threads, repeat, raw_file, expected = sys.argv[1:6]
expected = set(expected.split(","))

with open(perf_file, newline="", errors="replace") as f:
    rows = list(csv.reader(f))

with open(raw_file, "a", newline="") as f:
    writer = csv.writer(f)
    for row in rows:
        if len(row) < 3:
            continue
        event = row[2].strip()
        if event not in expected:
            continue
        try:
            value = float(row[0].strip().replace(" ", ""))
        except ValueError:
            continue
        if math.isfinite(value):
            writer.writerow([threads, repeat, "perf", event, value])
PY
}

# ============================================================
# Agregação final (também gera roofline.csv)
# ============================================================
finalize_results() {
    local rc=$?
    trap - EXIT

    python3 - "$RAW_RESULTS" "$RESULTS" <<'PY'
import csv, math, statistics, sys
from collections import defaultdict

raw_file, output_file = sys.argv[1:3]

rows_all = []
per_run = defaultdict(dict)

with open(raw_file, newline="") as f:
    for row in csv.DictReader(f):
        try:
            t = int(row["threads"]); r = int(row["repeat"])
            k = row["kind"]; m = row["metric"]; v = float(row["value"])
        except (ValueError, KeyError):
            continue
        rows_all.append((t, r, k, m, v))
        if k == "perf":
            per_run[(t, r)][m] = v

# Métrica derivada FLOPs (por repetição).
# NOTA: flops = dp_ops + 2*fma — confirmar com o kernel de calibração.
# Não são calculadas intensidade aritmética nem métricas de roofline.
for (t, r), d in per_run.items():
    need = ("fp_dp_fixed_ops_spec", "fp_fma_spec")
    if not all(m in d for m in need):
        continue
    flops = d["fp_dp_fixed_ops_spec"] + 2.0 * d["fp_fma_spec"]
    rows_all.append((t, r, "derived", "FLOPs", flops))

# Agregação por threads
groups = defaultdict(list)
for t, r, k, m, v in rows_all:
    if math.isfinite(v):
        groups[(t, k, m)].append(v)

with open(output_file, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["threads", "kind", "metric", "value", "samples", "stdev"])
    for (t, k, m), vs in sorted(groups.items()):
        mean = statistics.fmean(vs)
        sd = statistics.stdev(vs) if len(vs) > 1 else 0.0
        w.writerow([t, k, m, f"{mean:.12g}", len(vs), f"{sd:.12g}"])


PY

    exit "$rc"
}
trap finalize_results EXIT

# ============================================================
# Execuções
# ============================================================
for NTHREADS in "${THREADS[@]}"; do
    if (( NTHREADS > MAX_THREADS )); then
        continue
    fi

    for REP in $(seq 1 "$REPEATS"); do
        echo
        echo "================================================"
        echo "Threads: $NTHREADS | Repetição: $REP/$REPEATS"
        echo "================================================"

        # Corrida 1: FLOPs + tempo
        RUN1="$OUTDIR/outputs/threads_${NTHREADS}/rep_${REP}/flops"
        if ! run_perf_group flops "$EVENTS_FLOPS" "$RUN1"; then
            echo "ERRO: execução (flops) falhou: t=$NTHREADS r=$REP"
            echo "Execução falhou: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi
        parse_perf_csv "$OUTDIR/perf/perf_flops_t${NTHREADS}_r${REP}.csv" \
            "$EVENTS_FLOPS,seconds elapsed"

        # Corrida 2: memória + branches (é a que valida os resultados)
        RUN2="$OUTDIR/outputs/threads_${NTHREADS}/rep_${REP}/mem"
        if ! run_perf_group mem "$EVENTS_MEM" "$RUN2"; then
            echo "ERRO: execução (mem) falhou: t=$NTHREADS r=$REP"
            echo "Execução falhou: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi
        parse_perf_csv "$OUTDIR/perf/perf_mem_t${NTHREADS}_r${REP}.csv" "$EVENTS_MEM"

        AVERAGE="$RUN2/cp_average.txt"
        if [[ ! -f "$AVERAGE" ]]; then
            echo "ERRO: $AVERAGE não foi produzido."
            echo "cp_average.txt em falta: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi

        # ----------------------------------------------------
        # Validar cp_average.txt (NÃO guarda no CSV)
        # ----------------------------------------------------
        if ! python3 - "$AVERAGE" "$REFERENCE_ABS" "$NTHREADS" "$REP" <<'PY'
import csv, math, sys

average_file, reference_file, threads, repeat = sys.argv[1:5]

names = [
    "Total Time (s)", "T (K)", "P (Pa)", "PV/nT (J/(mol K))",
    "Z", "V (m^3)", "N",
]

numeric_rows = []
with open(average_file, errors="replace") as f:
    for line in f:
        tokens = line.split()
        if len(tokens) != 7:
            continue
        try:
            numeric_rows.append([float(t) for t in tokens])
        except ValueError:
            continue

if not numeric_rows:
    print("ERRO: não encontrei linha com 7 valores numéricos.", file=sys.stderr)
    sys.exit(2)

values = numeric_rows[-1]
index = {name: i for i, name in enumerate(names)}

references = {}
with open(reference_file, newline="") as f:
    for row in csv.DictReader(f):
        references[row["field"].strip()] = (
            float(row["expected"]), float(row["tolerance"]),
        )

failures = []
for field, (expected, tolerance) in references.items():
    if field == "Total Time (s)":
        continue
    if field not in index:
        print(f"ERRO: campo desconhecido: {field}", file=sys.stderr)
        sys.exit(2)
    actual = values[index[field]]
    if not math.isfinite(actual) or abs(actual - expected) > tolerance:
        failures.append((field, actual, expected, tolerance))

if failures:
    print(f"FALHA: threads={threads}, repetição={repeat}")
    for field, actual, expected, tol in failures:
        print(f"  {field}: obtido={actual:.12g}, esperado={expected:.12g}, tol={tol:.12g}")
    sys.exit(1)

print(f"Validação OK: threads={threads}, repetição={repeat}")
PY
        then
            echo "ERRO: validação falhou: t=$NTHREADS r=$REP"
            echo "Validação falhou: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi
    done
done

echo "Todas as execuções passaram na validação." > "$STATUS"
echo
echo "Benchmark concluído com sucesso."
echo "Resultados médios: $RESULTS"
echo "Estado: $STATUS"