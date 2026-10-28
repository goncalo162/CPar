
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
THREADS=(1 2 4 8 16 32 48)
MAX_THREADS=48

INPUT="inputdata.txt"
EXECUTABLE="md"
REFERENCE="reference.csv"

BASE_DIR="${SLURM_SUBMIT_DIR:-$PWD}"
cd "$BASE_DIR" || exit 1

JOB_ID="${SLURM_JOB_ID:-local}"
OUTDIR="$BASE_DIR/benchmark_${JOB_ID}"
mkdir -p "$OUTDIR/outputs" "$OUTDIR/perf" "$OUTDIR/plots"

RESULTS="$OUTDIR/results.csv"
STATUS="$OUTDIR/status.txt"

EVENTS="cycles,instructions,branches,branch-misses,L1-dcache-loads,L1-dcache-load-misses"

export OMP_DYNAMIC=FALSE
export OMP_PROC_BIND=close
export OMP_PLACES=cores

# Tolerâncias absolutas em reference.csv.
# Ajusta-as se necessário para a precisão do teu programa.

# ============================================================
# Verificações e compilação
# ============================================================
if [[ ! -f "$INPUT" ]]; then
    echo "ERRO: não encontrei $INPUT"
    exit 1
fi

if [[ ! -f "$REFERENCE" ]]; then
    echo "ERRO: não encontrei $REFERENCE"
    exit 1
fi

if ! command -v perf >/dev/null 2>&1; then
    echo "ERRO: perf não está disponível."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERRO: python3 não está disponível."
    exit 1
fi

if ! command -v gnuplot >/dev/null 2>&1; then
    echo "AVISO: gnuplot não está disponível; não serão gerados gráficos."
fi

if [[ -f Makefile ]]; then
    if ! make md; then
        echo "ERRO: a compilação falhou."
        exit 1
    fi
fi

if [[ ! -x "./$EXECUTABLE" ]]; then
    echo "ERRO: ./$EXECUTABLE não existe ou não é executável."
    exit 1
fi

EXEC_ABS="$BASE_DIR/$EXECUTABLE"
INPUT_ABS="$BASE_DIR/$INPUT"
REFERENCE_ABS="$BASE_DIR/$REFERENCE"

echo "===== Hardware do nó ====="
lscpu || true
echo "===== Configuração SLURM ====="
echo "CPUs atribuídas: ${SLURM_CPUS_PER_TASK:-desconhecido}"
echo "Threads a testar: ${THREADS[*]}"
echo

echo "threads,kind,metric,value" > "$RESULTS"
echo "Benchmark iniciado." > "$STATUS"

# ============================================================
# Geração de um gráfico PNG por métrica
# ============================================================
make_plots() {
    command -v gnuplot >/dev/null 2>&1 || return 0

    python3 - "$RESULTS" "$OUTDIR/plots" <<'PY'
import csv
import os
import re
import sys

results_file, plot_dir = sys.argv[1:3]
os.makedirs(plot_dir, exist_ok=True)

with open(results_file, newline="") as f:
    rows = list(csv.DictReader(f))

metrics = sorted({
    row["metric"]
    for row in rows
    if row["value"] not in ("", "NA")
})

for metric in metrics:
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_", metric)
    data_file = os.path.join(plot_dir, safe + ".dat")
    script_file = os.path.join(plot_dir, safe + ".gp")
    png_file = os.path.join(plot_dir, safe + ".png")

    points = {}
    for row in rows:
        if row["metric"] != metric:
            continue
        try:
            points[int(row["threads"])] = float(row["value"])
        except (ValueError, TypeError):
            pass

    if not points:
        continue

    with open(data_file, "w") as f:
        for n, value in sorted(points.items()):
            f.write(f"{n} {value:.12g}\n")

    def quote(value):
        return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"

    with open(script_file, "w") as f:
        f.write("set terminal pngcairo size 1000,650\n")
        f.write(f"set output {quote(png_file)}\n")
        f.write(f"set title {quote(metric)}\n")
        f.write("set xlabel 'Número de threads'\n")
        f.write("set ylabel 'Valor'\n")
        f.write("set grid\n")
        f.write("set key off\n")
        f.write("set logscale x 2\n")
        f.write(f"plot {quote(data_file)} using 1:2 with linespoints linewidth 2 pointtype 7\n")

for path in sorted(
    os.path.join(plot_dir, name)
    for name in os.listdir(plot_dir)
    if name.endswith(".gp")
):
    os.system("gnuplot " + "'" + path.replace("'", "'\\''") + "'")
PY
}

trap make_plots EXIT

# ============================================================
# Execução para cada número de threads
# ============================================================
for NTHREADS in "${THREADS[@]}"; do
    if (( NTHREADS > MAX_THREADS )); then
        continue
    fi

    RUN_DIR="$OUTDIR/outputs/run_${NTHREADS}"
    mkdir -p "$RUN_DIR"

    OUTPUT="$RUN_DIR/stdout.txt"
    STDERR_LOG="$RUN_DIR/stderr.txt"
    AVERAGE="$RUN_DIR/cp_average.txt"
    PERF_FILE="$OUTDIR/perf/perf_${NTHREADS}.csv"

    echo
    echo "================================================"
    echo "Execução com $NTHREADS threads"
    echo "================================================"

    # Cada run tem diretório próprio para não sobrescrever
    # cp_average.txt nem outros ficheiros gerados pelo programa.
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
        echo "ERRO: execução falhou com $NTHREADS threads."
        echo "Consultar $RUN_DIR e $PERF_FILE"
        echo "Execução falhou com $NTHREADS threads." > "$STATUS"
        exit 1
    fi

    if [[ ! -f "$AVERAGE" ]]; then
        echo "ERRO: a execução não produziu $AVERAGE"
        echo "Ficheiro cp_average.txt em falta com $NTHREADS threads." > "$STATUS"
        exit 1
    fi

    # --------------------------------------------------------
    # Validar os valores físicos, exceto Total Time (s).
    # O ficheiro tem 7 colunas numéricas:
    # time, T, P, PV/nT, Z, V, N
    # --------------------------------------------------------
    if ! python3 - \
        "$AVERAGE" "$REFERENCE_ABS" "$NTHREADS" "$RESULTS" <<'PY'
import csv
import math
import re
import sys

average_file, reference_file, threads, results_file = sys.argv[1:5]

names = [
    "Total Time (s)",
    "T (K)",
    "P (Pa)",
    "PV/nT (J/(mol K))",
    "Z",
    "V (m^3)",
    "N",
]

number_re = re.compile(
    r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"
)

numeric_lines = []
with open(average_file, errors="replace") as f:
    for line in f:
        tokens = line.split()
        if len(tokens) != 7:
            continue
        try:
            values = [float(token) for token in tokens]
        except ValueError:
            continue
        numeric_lines.append(values)

if not numeric_lines:
    print(
        "ERRO: não encontrei uma linha com 7 valores numéricos "
        "em cp_average.txt.",
        file=sys.stderr,
    )
    sys.exit(2)

# Usa a última linha numérica do ficheiro.
values = numeric_lines[-1]

# O tempo é guardado para análise, mas não é comparado.
with open(results_file, "a", newline="") as f:
    writer = csv.writer(f)
    for name, value in zip(names, values):
        writer.writerow([threads, "output", name, value])

references = {}
with open(reference_file, newline="") as f:
    for row in csv.DictReader(f):
        field = row["field"].strip()
        references[field] = (
            float(row["expected"]),
            float(row["tolerance"]),
        )

index_by_name = {name: i for i, name in enumerate(names)}
failures = []

for field, (expected, tolerance) in references.items():
    if field == "Total Time (s)":
        continue

    if field not in index_by_name:
        print(f"ERRO: campo de referência desconhecido: {field}", file=sys.stderr)
        sys.exit(2)

    actual = values[index_by_name[field]]
    if not math.isfinite(actual) or abs(actual - expected) > tolerance:
        failures.append((field, actual, expected, tolerance))

if failures:
    print(f"\nFALHA DE VALIDAÇÃO COM {threads} THREADS")
    for field, actual, expected, tolerance in failures:
        print(
            f"Campo: {field} | obtido: {actual:.12g} | "
            f"esperado: {expected:.12g} | tolerância: {tolerance:.12g}"
        )
    sys.exit(1)

print(f"Validação OK com {threads} threads.")
PY
    then
        echo "ERRO: valores incorretos com $NTHREADS threads."
        echo "Valores incorretos com $NTHREADS threads." > "$STATUS"
        exit 1
    fi

    # --------------------------------------------------------
    # Adicionar contadores perf ao CSV principal.
    # Contadores não suportados ou não contabilizados são ignorados.
    # --------------------------------------------------------
    python3 - "$PERF_FILE" "$NTHREADS" "$RESULTS" <<'PY'
import csv
import sys

perf_file, threads, results_file = sys.argv[1:4]

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

with open(results_file, "a", newline="") as f:
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
            print(f"Aviso: contador {event} sem valor numérico.")
            continue

        writer.writerow([threads, "perf", event, value])
PY

    echo "Run com $NTHREADS threads concluída e validada."
done

echo "Todas as execuções passaram na validação." > "$STATUS"
echo "Benchmark concluído."
echo "Resultados: $RESULTS"
echo "Gráficos: $OUTDIR/plots/"