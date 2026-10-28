
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

# Número de repetições por configuração.
# Pode ser passado como argumento: sbatch benchmark_threads.sh 5
REPEATS="${1:-3}"

THREADS=(1 2 4 8 16 32 48)
MAX_THREADS=48

INPUT="inputdata.txt"
EXECUTABLE="md"
REFERENCE="reference.csv"

EVENTS="cycles,instructions,branches,branch-misses,L1-dcache-loads,L1-dcache-load-misses"

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
    echo "Uso: sbatch benchmark_threads.sh 5"
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "Erro: não encontrei $INPUT"
    exit 1
fi

if [[ ! -f "$REFERENCE" ]]; then
    echo "Erro: não encontrei $REFERENCE"
    exit 1
fi

if ! command -v perf >/dev/null 2>&1; then
    echo "Erro: perf não está disponível."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Erro: python3 não está disponível."
    exit 1
fi

if [[ -f Makefile ]]; then
    if ! make md; then
        echo "Erro de compilação."
        exit 1
    fi
fi

if [[ ! -x "./$EXECUTABLE" ]]; then
    echo "Erro: ./$EXECUTABLE não existe ou não é executável."
    exit 1
fi

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
echo "Total máximo de execuções: $(( ${#THREADS[@]} * REPEATS ))"
echo

# O CSV bruto guarda todas as repetições.
echo "threads,repeat,kind,metric,value" > "$RAW_RESULTS"

# O CSV final guarda a média, desvio-padrão e número de amostras.
# A coluna value contém a média para manter compatibilidade
# com o plot_results.gp anterior.
echo "threads,kind,metric,value,samples,stdev" > "$RESULTS"

echo "Benchmark iniciado." > "$STATUS"

# ============================================================
# Agregação: gera results.csv mesmo que o job falhe a meio
# ============================================================

finalize_results() {
    local rc=$?
    trap - EXIT

    python3 - "$RAW_RESULTS" "$RESULTS" <<'PY'
import csv
import math
import statistics
import sys
from collections import defaultdict

raw_file, output_file = sys.argv[1:3]
groups = defaultdict(list)

with open(raw_file, newline="") as f:
    for row in csv.DictReader(f):
        try:
            key = (
                int(row["threads"]),
                row["kind"],
                row["metric"],
            )
            value = float(row["value"])
            if math.isfinite(value):
                groups[key].append(value)
        except (ValueError, KeyError):
            continue

with open(output_file, "w", newline="") as f:
    writer = csv.writer(f)
    writer.writerow([
        "threads", "kind", "metric", "value", "samples", "stdev"
    ])

    for (threads, kind, metric), values in sorted(groups.items()):
        mean = statistics.fmean(values)
        stdev = statistics.stdev(values) if len(values) > 1 else 0.0

        writer.writerow([
            threads,
            kind,
            metric,
            f"{mean:.12g}",
            len(values),
            f"{stdev:.12g}",
        ])

print(f"CSV agregado: {output_file}")
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
        RUN_DIR="$OUTDIR/outputs/threads_${NTHREADS}/rep_${REP}"
        mkdir -p "$RUN_DIR"

        OUTPUT="$RUN_DIR/stdout.txt"
        STDERR_LOG="$RUN_DIR/stderr.txt"
        AVERAGE="$RUN_DIR/cp_average.txt"
        PERF_FILE="$OUTDIR/perf/perf_t${NTHREADS}_r${REP}.csv"

        echo
        echo "================================================"
        echo "Threads: $NTHREADS | Repetição: $REP/$REPEATS"
        echo "================================================"

        if ! (
            cd "$RUN_DIR" &&
            srun --cpu-bind=cores \
                perf stat -x, -o "$PERF_FILE" \
                -e "$EVENTS" \
                -- env \
                    OMP_NUM_THREADS="$NTHREADS" \
                    OMP_DYNAMIC=FALSE \
                    OMP_PROC_BIND=close \
                    OMP_PLACES=cores \
                    "$EXEC_ABS" \
                    < "$INPUT_ABS" \
                    > "$OUTPUT" \
                    2> "$STDERR_LOG"
        ); then
            echo "ERRO: execução falhou com $NTHREADS threads, repetição $REP."
            echo "Execução falhou: threads=$NTHREADS, repetição=$REP" > "$STATUS"
            exit 1
        fi

        if [[ ! -f "$AVERAGE" ]]; then
            echo "ERRO: $AVERAGE não foi produzido."
            echo "cp_average.txt em falta: threads=$NTHREADS, repetição=$REP" > "$STATUS"
            exit 1
        fi

        # ----------------------------------------------------
        # Registar contadores perf desta repetição.
        # ----------------------------------------------------
        python3 - "$PERF_FILE" "$NTHREADS" "$REP" "$RAW_RESULTS" <<'PY'
import csv
import math
import sys

perf_file, threads, repeat, raw_file = sys.argv[1:5]

expected_events = {
    "cycles",
    "instructions",
    "branches",
    "branch-misses",
    "L1-dcache-loads",
    "L1-dcache-load-misses",
}

with open(perf_file, newline="", errors="replace") as f:
    rows = list(csv.reader(f))

with open(raw_file, "a", newline="") as f:
    writer = csv.writer(f)

    for row in rows:
        if len(row) < 3:
            continue

        event = row[2].strip()
        raw_value = row[0].strip()

        if event not in expected_events:
            continue

        try:
            value = float(raw_value.replace(" ", ""))
        except ValueError:
            print(f"Aviso: perf não forneceu um valor numérico para {event}.")
            continue

        if not math.isfinite(value):
            continue

        writer.writerow([threads, repeat, "perf", event, value])
PY

        # ----------------------------------------------------
        # Ler cp_average.txt, guardar os campos e validar.
        # Total Time (s) é registado, mas não é validado.
        # ----------------------------------------------------
        if ! python3 - \
            "$AVERAGE" "$REFERENCE_ABS" "$NTHREADS" "$REP" "$RAW_RESULTS" <<'PY'
import csv
import math
import sys

average_file, reference_file, threads, repeat, raw_file = sys.argv[1:6]

names = [
    "Total Time (s)",
    "T (K)",
    "P (Pa)",
    "PV/nT (J/(mol K))",
    "Z",
    "V (m^3)",
    "N",
]

numeric_rows = []

with open(average_file, errors="replace") as f:
    for line in f:
        tokens = line.split()
        if len(tokens) != 7:
            continue
        try:
            row = [float(token) for token in tokens]
        except ValueError:
            continue
        numeric_rows.append(row)

if not numeric_rows:
    print("ERRO: não encontrei uma linha com 7 valores numéricos.", file=sys.stderr)
    sys.exit(2)

values = numeric_rows[-1]

with open(raw_file, "a", newline="") as f:
    writer = csv.writer(f)
    for name, value in zip(names, values):
        writer.writerow([threads, repeat, "output", name, value])

references = {}
with open(reference_file, newline="") as f:
    for row in csv.DictReader(f):
        field = row["field"].strip()
        references[field] = (
            float(row["expected"]),
            float(row["tolerance"]),
        )

index = {name: i for i, name in enumerate(names)}
failures = []

for field, (expected, tolerance) in references.items():
    # O tempo não participa na validação.
    if field == "Total Time (s)":
        continue

    if field not in index:
        print(f"ERRO: campo desconhecido na referência: {field}", file=sys.stderr)
        sys.exit(2)

    actual = values[index[field]]

    if not math.isfinite(actual) or abs(actual - expected) > tolerance:
        failures.append((field, actual, expected, tolerance))

if failures:
    print(f"\nFALHA: threads={threads}, repetição={repeat}")
    for field, actual, expected, tolerance in failures:
        print(
            f"  {field}: obtido={actual:.12g}, "
            f"esperado={expected:.12g}, tolerância={tolerance:.12g}"
        )
    sys.exit(1)

print(f"Validação OK: threads={threads}, repetição={repeat}")
PY
        then
            echo "ERRO: validação falhou com $NTHREADS threads, repetição $REP."
            echo "Validação falhou: threads=$NTHREADS, repetição=$REP" > "$STATUS"
            exit 1
        fi
    done
done

echo "Todas as execuções passaram na validação." > "$STATUS"
echo
echo "Benchmark concluído com sucesso."
echo "Resultados médios: $RESULTS"
echo "Resultados individuais: $RAW_RESULTS"
echo "Estado: $STATUS"