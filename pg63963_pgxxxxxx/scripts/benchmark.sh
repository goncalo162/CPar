#!/bin/bash
#SBATCH -A f202500010hpcvlabuminhoa
#SBATCH -p normal-arm
#SBATCH -t 30:00
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

# 1 thread = baseline do speedup: corre UMA única vez
# (tempo e contadores de memória vêm da mesma corrida).
BASELINE_THREADS=1
THREADS=(1 8 16 32 48 64 96 128 144 192)
MAX_THREADS=192

INPUT="inputdata.txt"
EXECUTABLE="md"
REFERENCE="reference.csv"
REFERENCE_FULL="reference_full.txt"
DIGIT_PRECISION=12

# Grupo 1: FLOPs e tempo (para o eixo Y do roofline)
EVENTS_FLOPS="task-clock,cycles,instructions,fp_dp_fixed_ops_spec,fp_fma_spec"
# Grupo 2: memória e branches (para o eixo X do roofline)
EVENTS_MEM="br_pred,br_mis_pred,L1-dcache-loads,L1-dcache-load-misses,l2d_cache_refill"
# Todos juntos (usado só na corrida única do baseline)
EVENTS_ALL="$EVENTS_FLOPS,$EVENTS_MEM"

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
[[ -f "$REFERENCE_FULL" ]] || { echo "Erro: não encontrei $REFERENCE_FULL"; exit 1; }
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
echo "Repetições por configuração: $REPEATS (baseline de $BASELINE_THREADS thread: 1 corrida)"

# CSV bruto: todas as repetições (só perf; averages só validam)
echo "threads,repeat,kind,metric,value" > "$RAW_RESULTS"
# CSV final: médias
echo "threads,kind,metric,value,samples,stdev" > "$RESULTS"

echo "Benchmark iniciado." > "$STATUS"

# ============================================================
# Executa uma corrida do md com um grupo de eventos perf
# (guarda o tempo de parede em LAST_ELAPSED)
# ============================================================
LAST_ELAPSED=0

run_perf_group() {
    local group=$1 events=$2 run_dir=$3
    local perf_file="$OUTDIR/perf/perf_${group}_t${NTHREADS}_r${REP}.csv"
    local t0 t1 rc

    mkdir -p "$run_dir"
    t0=$(date +%s.%N)
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
    rc=$?
    t1=$(date +%s.%N)
    LAST_ELAPSED=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f", b-a}')
    return $rc
}

# Regista os contadores de um ficheiro perf no CSV bruto
parse_perf_csv() {
    local perf_file=$1 expected=$2
    python3 - "$perf_file" "$NTHREADS" "$REP" "$RAW_RESULTS" "$expected" <<'PY'
import csv, math, sys

perf_file, threads, repeat, raw_file, expected = sys.argv[1:6]
expected = set(expected.split(","))
# aceitar tanto o nome canónico como o alias de perf
if "seconds elapsed" in expected:
    expected.add("seconds time elapsed")

with open(perf_file, newline="", errors="replace") as f:
    rows = list(csv.reader(f))

with open(raw_file, "a", newline="") as f:
    writer = csv.writer(f)
    for row in rows:
        if len(row) < 2:
            continue
        try:
            value = float(row[0].strip().replace(" ", "").replace("\u202f", ""))
        except ValueError:
            continue
        if not math.isfinite(value):
            continue

        # Determina o nome do evento
        if "seconds time elapsed" in ",".join(row):
            event = "seconds elapsed"
        elif len(row) >= 3:
            event = row[2].strip()
        else:
            event = row[1].strip()

        if event not in expected:
            continue
        writer.writerow([threads, repeat, "perf", event, value])
PY
}

# Valida cp_average.txt contra o reference.csv (NÃO guarda no CSV)
validate_run() {
    local average_file=$1
    python3 - "$average_file" "$REFERENCE_ABS" "$NTHREADS" "$REP" <<'PY'
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
}

# Valida cp_output.txt contra reference_full.txt, dígito a dígito
validate_full_run() {
    local output_file=$1
    python3 - "$output_file" "$REFERENCE_FULL" "$DIGIT_PRECISION" "$NTHREADS" "$REP" <<'PY'
import sys

output_file, reference_file, digit_precision, threads, repeat = sys.argv[1:6]
digit_precision = int(digit_precision)

def digits_of(token):
    # mantém apenas [0-9], ignora +, -, . e e/E
    return "".join(ch for ch in token if ch.isdigit())

def tokens(line):
    return line.split()

def data_rows(path):
    rows = []
    with open(path, errors="replace") as f:
        for line in f:
            t = tokens(line)
            if len(t) != 6:
                continue  # ignora cabeçalho e linhas inválidas
            try:
                [float(x) for x in t]
            except ValueError:
                continue
            rows.append(t)
    return rows

ref_rows = data_rows(reference_file)
out_rows = data_rows(output_file)

if len(ref_rows) != len(out_rows):
    print(f"FALHA: threads={threads}, repetição={repeat}: "
          f"nº de linhas difere (obtido={len(out_rows)}, esperado={len(ref_rows)})",
          file=sys.stderr)
    sys.exit(1)

for i, (ref_t, out_t) in enumerate(zip(ref_rows, out_rows)):
    for col, (rv, ov) in enumerate(zip(ref_t, out_t)):
        rd = digits_of(rv)
        od = digits_of(ov)
        # se algum dos lados tiver menos dígitos que a precisão,
        # compara na totalidade
        n = digit_precision
        if len(rd) < n or len(od) < n:
            n = min(len(rd), len(od))
        if rd[:n] != od[:n]:
            print(f"FALHA: threads={threads}, repetição={repeat}: "
                  f"linha {i+1}, coluna {col+1}: "
                  f"obtido={ov} (dígitos {od[:n]}), "
                  f"esperado={rv} (dígitos {rd[:n]})", file=sys.stderr)
            sys.exit(1)

print(f"Validação completa OK: threads={threads}, repetição={repeat}")
PY
}

# ============================================================
# Agregação final
# ============================================================
finalize_results() {
    local rc=$?
    trap - EXIT

    python3 - "$RAW_RESULTS" "$RESULTS" <<'PY'
import csv, math, statistics, sys, os
from collections import defaultdict

raw_file, output_file = sys.argv[1:3]

rows_all = []
per_run = defaultdict(dict)

if os.path.exists(raw_file):
    with open(raw_file, newline="", errors="replace") as f:
        for row in csv.DictReader(f):
            try:
                t = int(row["threads"]); r = int(row["repeat"])
                k = row["kind"]; m = row["metric"]; v = float(row["value"])
            except (ValueError, KeyError, TypeError):
                continue
            rows_all.append((t, r, k, m, v))
            if k == "perf":
                per_run[(t, r)][m] = v

# FLOPs derivado (por repetição)
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
        mean = sum(vs) / len(vs) if vs else 0.0
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

    # Baseline: uma única corrida; restantes: REPEATS repetições
    if (( NTHREADS == BASELINE_THREADS )); then
        N_REPS=1
    else
        N_REPS=$REPEATS
    fi

    for REP in $(seq 1 "$N_REPS"); do
        echo
        echo "================================================"
        echo "Threads: $NTHREADS | Repetição: $REP/$N_REPS"
        echo "================================================"

        if (( NTHREADS == BASELINE_THREADS )); then
            # ---- Corrida única: todos os eventos + tempo ----
            RUN="$OUTDIR/outputs/threads_${NTHREADS}/rep_${REP}/all"
            if ! run_perf_group all "$EVENTS_ALL" "$RUN"; then
                echo "ERRO: execução (all) falhou: t=$NTHREADS r=$REP"
                echo "Execução falhou: t=$NTHREADS r=$REP" > "$STATUS"
                exit 1
            fi
            parse_perf_csv "$OUTDIR/perf/perf_all_t${NTHREADS}_r${REP}.csv" \
                "$EVENTS_ALL,seconds elapsed"
            echo "$NTHREADS,$REP,perf,seconds elapsed,$LAST_ELAPSED" >> "$RAW_RESULTS"
            AVERAGE="$RUN/cp_average.txt"
        else
            # ---- Corrida 1: FLOPs + tempo ----
            RUN1="$OUTDIR/outputs/threads_${NTHREADS}/rep_${REP}/flops"
            if ! run_perf_group flops "$EVENTS_FLOPS" "$RUN1"; then
                echo "ERRO: execução (flops) falhou: t=$NTHREADS r=$REP"
                echo "Execução falhou: t=$NTHREADS r=$REP" > "$STATUS"
                exit 1
            fi
            parse_perf_csv "$OUTDIR/perf/perf_flops_t${NTHREADS}_r${REP}.csv" \
                "$EVENTS_FLOPS,seconds elapsed"
            echo "$NTHREADS,$REP,perf,seconds elapsed,$LAST_ELAPSED" >> "$RAW_RESULTS"

            # ---- Corrida 2: memória + branches (valida os resultados) ----
            RUN2="$OUTDIR/outputs/threads_${NTHREADS}/rep_${REP}/mem"
            if ! run_perf_group mem "$EVENTS_MEM" "$RUN2"; then
                echo "ERRO: execução (mem) falhou: t=$NTHREADS r=$REP"
                echo "Execução falhou: t=$NTHREADS r=$REP" > "$STATUS"
                exit 1
            fi
            parse_perf_csv "$OUTDIR/perf/perf_mem_t${NTHREADS}_r${REP}.csv" \
                "$EVENTS_MEM"
            echo "$NTHREADS,$REP,perf,seconds elapsed,$LAST_ELAPSED" >> "$RAW_RESULTS"
            AVERAGE="$RUN2/cp_average.txt"
        fi

        if [[ ! -f "$AVERAGE" ]]; then
            echo "ERRO: $AVERAGE não foi produzido."
            echo "cp_average.txt em falta: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi

        if ! validate_run "$AVERAGE"; then
            echo "ERRO: validação falhou: t=$NTHREADS r=$REP"
            echo "Validação falhou: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi

        # Deriva cp_output.txt a partir do caminho do cp_average.txt
        OUTPUT_FILE="${AVERAGE/_average.txt/_output.txt}"
        if [[ ! -f "$OUTPUT_FILE" ]]; then
            echo "ERRO: $OUTPUT_FILE não foi produzido."
            echo "cp_output.txt em falta: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi

        if ! validate_full_run "$OUTPUT_FILE"; then
            echo "ERRO: validação completa falhou: t=$NTHREADS r=$REP"
            echo "Validação completa falhou: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi
    done
done

echo "Todas as execuções passaram na validação." > "$STATUS"
echo
echo "Benchmark concluído com sucesso."
echo "Resultados médios: $RESULTS"
echo "Estado: $STATUS"