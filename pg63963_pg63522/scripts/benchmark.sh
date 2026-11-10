#!/bin/bash
#SBATCH -A f202500010hpcvlabuminhoa
#SBATCH -p normal-arm
#SBATCH -t 20:00
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
BASELINE_THREADS=1
THREADS=(1 8 16 32 48 64 96 128 144 192)
MAX_THREADS=192

INPUT="inputdata.txt"
EXECUTABLE="md"
REFERENCE="compare/reference.csv"
REFERENCE_FULL="compare/reference_full.txt"

# Validação do output por passo (reference_full.txt):
#  1) T e P: diferença <= tolerância do reference.csv -> passa
#  2) diferença <= PRINT_ULP_TOL (resolução de %20.8f) -> passa
#  3) senão, compara DIGIT_PRECISION algarismos significativos
DIGIT_PRECISION=12
PRINT_ULP_TOL=2e-8

# ---- Eventos do PROGRAMA (perf stat sobre o md: só conta o que o md faz) ----
# FLOPs por precisão = fp_X_fixed_ops_spec + fp_X_scale_ops_spec
# (os CPUs Fujitsu já multiplicam no "scale" pelo VL do SVE e as FMA contam 2)
EVENTS_PROG="task-clock,cycles,instructions,br_pred,br_mis_pred,L1-dcache-loads,L1-dcache-load-misses,l2d_cache_refill,fp_dp_fixed_ops_spec,fp_dp_scale_ops_spec,fp_sp_fixed_ops_spec,fp_sp_scale_ops_spec,fp_hp_fixed_ops_spec,fp_hp_scale_ops_spec"

# ---- Eventos de MEMÓRIA (sistema, só nestes cores: 1 por CMG do A64FX) ----
# Correm num perf em segundo plano durante a MESMA execução do md.
EVENTS_BUS="bus_read_total_mem,bus_write_total_mem"
BUS_CPUS="0,12,24,36"
BUS_BYTES=256            # bytes por contagem de bus_read/write_total_mem

# Tempo de parede medido pelo próprio perf (ns): só o md,
# sem o arranque do srun nem do perf.
EVENT_TIME="duration_time"

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

# O perf tem de suportar duration_time, senão não há tempos
perf stat -x, -o "$OUTDIR/perf/probe.csv" -e "$EVENT_TIME" -- true >/dev/null 2>&1 \
    && grep -q "$EVENT_TIME" "$OUTDIR/perf/probe.csv" \
    || { echo "Erro: este perf não suporta o evento $EVENT_TIME."; exit 1; }

# O perf tem de conseguir contar bus_* em modo sistema nos cores BUS_CPUS
perf stat -a -C "$BUS_CPUS" -x, -o "$OUTDIR/perf/probe_bus.csv" -e "$EVENTS_BUS" -- true >/dev/null 2>&1 \
    && grep -q "bus_read_total_mem" "$OUTDIR/perf/probe_bus.csv" \
    && grep -q "bus_write_total_mem" "$OUTDIR/perf/probe_bus.csv" \
    && ! grep -qE "not (counted|supported)" "$OUTDIR/perf/probe_bus.csv" \
    || { echo "Erro: não consigo contar $EVENTS_BUS em modo sistema nos cores $BUS_CPUS (perf_event_paranoid? evento inexistente?)."; exit 1; }

ml GCC

if [[ -f Makefile ]]; then
    make clean || { echo "Erro no make clean."; exit 1; }
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
echo "Cores dos contadores de memória: $BUS_CPUS"
echo "Repetições por configuração: $REPEATS (baseline de $BASELINE_THREADS thread: 1 corrida)"

# CSV bruto: todas as repetições (só perf; averages só validam)
echo "threads,repeat,kind,metric,value" > "$RAW_RESULTS"
# CSV final: médias
echo "threads,kind,metric,value,samples,stdev" > "$RESULTS"

echo "Benchmark iniciado." > "$STATUS"

# ============================================================
# UMA corrida do md por (threads, repetição).
#  - perf do programa: eventos do md + duration_time (tempo)
#  - perf em segundo plano: bus_* nos cores BUS_CPUS durante a mesma corrida
# ============================================================
run_perf() {
    local run_dir=$1 bus_pid rc=0

    mkdir -p "$run_dir"
    rm -f "$BUS_FILE"

    perf stat -a -C "$BUS_CPUS" -x, -o "$BUS_FILE" -e "$EVENTS_BUS" \
        2> "$run_dir/perf_bus.err" &
    bus_pid=$!
    sleep 0.5   # deixa o perf de fundo arrancar antes do md

    (
        cd "$run_dir" &&
        srun --cpu-bind=cores \
            perf stat -x, -o "$PROG_FILE" \
            -e "$EVENTS_PROG,$EVENT_TIME" \
            -- env \
                OMP_NUM_THREADS="$NTHREADS" \
                OMP_DYNAMIC=FALSE \
                OMP_PROC_BIND=close \
                OMP_PLACES=cores \
                "$EXEC_ABS" \
                < "$INPUT_ABS" \
                > "$run_dir/stdout.txt" \
                2> "$run_dir/stderr.txt"
    ) || rc=$?

    kill -INT "$bus_pid" 2>/dev/null
    wait "$bus_pid" 2>/dev/null || true
    return "$rc"
}

# Regista os contadores de um ficheiro perf no CSV bruto.
#   $3 = 1: exige duration_time (tempo)   |   0: exige todos os eventos de $2
# Linhas repetidas do mesmo evento (um por CPU) são somadas.
parse_perf_csv() {
    local perf_file=$1 expected=$2 need_time=$3 rc
    python3 - "$perf_file" "$NTHREADS" "$REP" "$RAW_RESULTS" "$expected" "$need_time" <<'PY'
import csv, math, sys

perf_file, threads, repeat, raw_file, expected, need_time = sys.argv[1:7]
need_time = need_time == "1"
expected = set(expected.split(","))
if need_time:
    expected.add("duration_time")

# duration_time vem em ns; converte para segundos
TO_SECONDS = {"": 1e-9, "ns": 1e-9, "us": 1e-6, "usec": 1e-6,
              "ms": 1e-3, "msec": 1e-3, "s": 1.0, "sec": 1.0}

try:
    with open(perf_file, newline="", errors="replace") as f:
        rows = list(csv.reader(f))
except OSError:
    sys.exit(1)

sums = {}
for row in rows:
    fields = [x.strip() for x in row]
    # formato: [prefixo cpu,] valor, unidade, evento, ...
    idx = next((i for i, x in enumerate(fields) if x in expected), None)
    if idx is None or idx < 2:
        continue
    try:
        value = float(fields[idx - 2].replace(" ", "").replace("\u202f", ""))
    except ValueError:
        continue
    if not math.isfinite(value):
        continue
    event, unit = fields[idx], fields[idx - 1]
    if event == "duration_time":
        value *= TO_SECONDS.get(unit, 1e-9)
    elif event == "task-clock":          # guardado sempre em ms
        value *= TO_SECONDS.get(unit, 1e-3) / 1e-3
    sums[event] = sums.get(event, 0.0) + value

with open(raw_file, "a", newline="") as f:
    writer = csv.writer(f)
    for event, value in sums.items():
        name = "seconds elapsed" if event == "duration_time" else event
        writer.writerow([threads, repeat, "perf", name, value])

ok = ("duration_time" in sums) if need_time else expected.issubset(sums)
sys.exit(0 if ok else 1)
PY
    rc=$?
    if (( rc != 0 )); then
        echo "ERRO: eventos em falta em $perf_file: t=$NTHREADS r=$REP"
        echo "Eventos perf em falta ($perf_file): t=$NTHREADS r=$REP" > "$STATUS"
        exit 1
    fi
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

# Valida cp_output.txt contra reference_full.txt:
# 1) T e P: dentro da tolerância do reference.csv -> passa
# 2) T, P, KE, PE, Total: diferença <= PRINT_ULP_TOL (resolução do %20.8f) -> passa
# 3) senão (e para time): compara DIGIT_PRECISION algarismos significativos
validate_full_run() {
    local output_file=$1

    python3 - "$output_file" "$REFERENCE_FULL" "$REFERENCE_ABS" "$DIGIT_PRECISION" "$PRINT_ULP_TOL" "$NTHREADS" "$REP" <<'PY'
import csv, sys
from decimal import Decimal, InvalidOperation

(output_file, reference_file, tol_file,
 precision, ulp_tol, threads, repeat) = sys.argv[1:8]
precision = int(precision)
ulp_tol = Decimal(ulp_tol)

tols = {}
with open(tol_file, newline="") as f:
    for row in csv.DictReader(f):
        tols[row["field"].strip()] = Decimal(row["tolerance"])

COLS = ["time", "T (K)", "P (Pa)", "KE", "PE", "E_total"]
# tolerância do CSV (None = não existe)
COL_TOL = [None, tols["T (K)"], tols["P (Pa)"], None, None, None]
# tolerância de resolução de impressão (time usa %8.4e, fica só por dígitos)
COL_ULP = [None, ulp_tol, ulp_tol, ulp_tol, ulp_tol, ulp_tol]


def data_rows(path):
    rows = []
    with open(path, errors="replace") as f:
        for line in f:
            tokens = line.split()
            if len(tokens) != 6:
                continue
            try:
                values = [Decimal(x) for x in tokens]
            except InvalidOperation:
                continue
            if not all(v.is_finite() for v in values):
                continue
            rows.append(values)
    return rows


def significant_digits(value, n):
    if value.is_zero():
        return ("0", 0)
    _, digits, _ = value.copy_abs().as_tuple()
    digits = "".join(map(str, digits)).rstrip("0")
    return digits[:n], value.copy_abs().adjusted()


ref_rows = data_rows(reference_file)
out_rows = data_rows(output_file)

if not ref_rows or len(ref_rows) != len(out_rows):
    print(f"FALHA: threads={threads}, repetição={repeat}: "
          f"nº de linhas inválido "
          f"(obtido={len(out_rows)}, esperado={len(ref_rows)})",
          file=sys.stderr)
    sys.exit(1)

via_tol = via_ulp = via_digits = 0
worst_ulp = [Decimal(0)] * 6   # maior diferença por coluna

for i, (ref_t, out_t) in enumerate(zip(ref_rows, out_rows)):
    for col, (rv, ov) in enumerate(zip(ref_t, out_t)):
        diff = abs(ov - rv)
        worst_ulp[col] = max(worst_ulp[col], diff)

        # 1) tolerância do reference.csv
        tol = COL_TOL[col]
        if tol is not None and diff <= tol:
            via_tol += 1
            continue

        # 2) resolução de impressão
        ulp = COL_ULP[col]
        if ulp is not None and diff <= ulp:
            via_ulp += 1
            continue

        # 3) dígitos significativos
        ref_digits, ref_exp = significant_digits(rv, precision)
        out_digits, out_exp = significant_digits(ov, precision)
        if ref_digits == out_digits and ref_exp == out_exp:
            via_digits += 1
            continue

        print(
            f"FALHA: threads={threads}, repetição={repeat}: "
            f"linha {i+1}, coluna {col+1} ({COLS[col]})\n"
            f"  Obtido:    {ov}\n"
            f"  Esperado:  {rv}\n"
            f"  Diferença: {diff:.6e}\n"
            f"  Dígitos obtidos:   {out_digits} (expoente {out_exp})\n"
            f"  Dígitos esperados: {ref_digits} (expoente {ref_exp})",
            file=sys.stderr
        )
        sys.exit(1)

worst = ", ".join(f"{c}={float(w):.1e}" for c, w in zip(COLS, worst_ulp))
print(f"Validação completa OK: threads={threads}, repetição={repeat} "
      f"(tol={via_tol}, ulp={via_ulp}, dígitos={via_digits}) "
      f"[maior diferença: {worst}]")
PY
}

# ============================================================
# Agregação final
# ============================================================
finalize_results() {
    local rc=$?
    trap - EXIT

    python3 - "$RAW_RESULTS" "$RESULTS" "$BUS_BYTES" <<'PY'
import csv, math, statistics, sys, os
from collections import defaultdict

raw_file, output_file, bus_bytes = sys.argv[1:4]
bus_bytes = float(bus_bytes)

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

# Métricas derivadas (por repetição)
FLOP_TYPES = (
    ("f64", "fp_dp_fixed_ops_spec", "fp_dp_scale_ops_spec"),
    ("f32", "fp_sp_fixed_ops_spec", "fp_sp_scale_ops_spec"),
    ("f16", "fp_hp_fixed_ops_spec", "fp_hp_scale_ops_spec"),
)
for (t, r), d in per_run.items():
    # FLOPs por precisão = fixed + scale (o scale já inclui o VL do SVE e FMA = 2)
    for tag, fixed, scale in FLOP_TYPES:
        if fixed in d and scale in d:
            rows_all.append((t, r, "derived", f"FLOPs_{tag}", d[fixed] + d[scale]))

    # Memória: (leituras + escritas dos 4 cores) x 256 B ; GB/s = bytes / T / 1e9
    if "bus_read_total_mem" in d and "bus_write_total_mem" in d:
        nbytes = (d["bus_read_total_mem"] + d["bus_write_total_mem"]) * bus_bytes
        rows_all.append((t, r, "derived", "mem_bytes", nbytes))
        secs = d.get("seconds elapsed", 0.0)
        if secs > 0:
            rows_all.append((t, r, "derived", "mem_bw_GBs", nbytes / secs / 1e9))

    # Frequência média: ciclos / tempo de CPU (task-clock em ms), 1 casa decimal em GHz
    if d.get("task-clock", 0.0) > 0 and "cycles" in d:
        ghz = d["cycles"] / (d["task-clock"] * 1e6)
        rows_all.append((t, r, "derived", "freq_GHz", round(ghz, 1)))

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
        if m == "freq_GHz":
            mean = round(mean, 1)
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

        RUN="$OUTDIR/outputs/threads_${NTHREADS}/rep_${REP}"
        PROG_FILE="$OUTDIR/perf/perf_prog_t${NTHREADS}_r${REP}.csv"
        BUS_FILE="$OUTDIR/perf/perf_bus_t${NTHREADS}_r${REP}.csv"

        if ! run_perf "$RUN"; then
            echo "ERRO: execução falhou: t=$NTHREADS r=$REP"
            echo "Execução falhou: t=$NTHREADS r=$REP" > "$STATUS"
            exit 1
        fi

        parse_perf_csv "$PROG_FILE" "$EVENTS_PROG" 1
        parse_perf_csv "$BUS_FILE"  "$EVENTS_BUS"  0

        AVERAGE="$RUN/cp_average.txt"
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