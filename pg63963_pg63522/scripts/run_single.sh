#!/bin/bash
set -euo pipefail

# Corre UMA run do md no cluster (job sbatch de 2 minutos) e mostra o resultado.
#
# Uso:
#   scripts/run_single.sh              # compila (make md) e corre (make runTest)
#   scripts/run_single.sh --u          # envia primeiro os ficheiros (scripts/upload_files.sh)
#   THREADS=16 scripts/run_single.sh   # nº de threads (por defeito 48)
#
# Resultados em single_<JOBID>/: logs do job, cp_average.txt e cp_output.txt.

# ============================================================
# Parâmetros do job
# ============================================================
ACCOUNT="f202500010hpcvlabuminhoa"
PARTITION="normal-arm"
TIME_LIMIT="00:02:00"
CPUS=48
THREADS="${THREADS:-48}"
OMP_ENV=""   # igual ao benchmark.sh
POLL_INTERVAL=10    # segundos entre verificações do estado do job

# ---- argumentos ----
UPDATE=0
for arg in "$@"; do
    case "$arg" in
        --u|-u|--update) UPDATE=1 ;;
        -h|--help)
            echo "Uso: $0 [--u]   (--u: envia os ficheiros para o cluster antes de correr)"
            exit 0 ;;
        *)
            echo "Argumento desconhecido: $arg (usa --u ou --help)" >&2
            exit 1 ;;
    esac
done

if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Erro: THREADS inválido: $THREADS" >&2
    exit 1
fi

# ============================================================
# Configuração (KEY, USER_HOST, PART_REMOTE_DIR vêm do .env)
# ============================================================
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$ROOT/.env"; set +a   # KEY, USER_HOST, PART_REMOTE_DIR

REMOTE_COMMON_DIR="/projects/F202500010HPCVLABUMINHO"
REMOTE_DIR="$REMOTE_COMMON_DIR/${PART_REMOTE_DIR#/}"

# Uma única ligação SSH partilhada: a password só é pedida ao abri-la
CM_SOCK="$HOME/.ssh/cm-$(printf '%s' "$USER_HOST" | cksum | cut -d' ' -f1)"
SSH_OPTS=(-i "$KEY" -o "ControlPath=$CM_SOCK")
ssh_run() { ssh -x "${SSH_OPTS[@]}" "$USER_HOST" "$@"; }
scp_run() { scp "${SSH_OPTS[@]}" "$@"; }
ensure_connection() {
    ssh "${SSH_OPTS[@]}" -O check "$USER_HOST" >/dev/null 2>&1 && return 0
    rm -f "$CM_SOCK"
    ssh -x "${SSH_OPTS[@]}" -o ControlMaster=yes -o ControlPersist="${CM_PERSIST:-2h}" "$USER_HOST" true
}

cd "$ROOT"

# ============================================================
# 0. Ligação SSH (única vez em que pede a password) e update opcional
# ============================================================
ensure_connection

if (( UPDATE )); then
    echo "== A atualizar os ficheiros no cluster (--u) =="
    bash "$ROOT/scripts/upload_files.sh"
fi

# ============================================================
# 1. Submeter o job (compila e corre uma vez)
# ============================================================
# Apaga resultados antigos para nunca copiar ficheiros de outra run.
JOB_CMD="ml GCC; make clean; make md && $OMP_ENV OMP_NUM_THREADS=$THREADS make runTest"

echo "== A submeter a run (limite $TIME_LIMIT, $THREADS threads) =="
JOB_ID=$(ssh_run "cd '$REMOTE_DIR' && sbatch --parsable -J md_single -A $ACCOUNT -p $PARTITION -t $TIME_LIMIT --nodes=1 --ntasks=1 --cpus-per-task=$CPUS -o single_%j.out -e single_%j.err --wrap '$JOB_CMD'" \
    | cut -d';' -f1)

if ! [[ "$JOB_ID" =~ ^[0-9]+$ ]]; then
    echo "Erro: não consegui obter o ID do job. Output recebido: $JOB_ID"
    exit 1
fi
echo "Job submetido: $JOB_ID"

# ============================================================
# 2. Esperar pelo fim do job
# ============================================================
echo "== A aguardar o fim do job (verifica a cada ${POLL_INTERVAL}s) =="

while true; do
    ensure_connection   # só volta a pedir password se a ligação tiver caído
    STATE=$(ssh_run "squeue --job $JOB_ID --noheader --format='%T %M' 2>/dev/null" || true)
    if [[ -z "$STATE" ]]; then
        break
    fi
    echo "  Estado: $STATE ($(date +%H:%M:%S))"
    sleep "$POLL_INTERVAL"
done

# Estado final (o sacct pode demorar um instante a registar o fim)
STATE=""
for _ in 1 2 3 4 5; do
    STATE=$(ssh_run "sacct -j $JOB_ID --noheader --format=State | head -n1 | xargs" || true)
    case "$STATE" in
        RUNNING*|PENDING*|COMPLETING*|"") sleep 2 ;;
        *) break ;;
    esac
done

# ============================================================
# 3. Copiar e mostrar os resultados (mesmo se o job falhou)
# ============================================================
LOCAL_OUT="$ROOT/single_$JOB_ID"
mkdir -p "$LOCAL_OUT"
for f in "single_$JOB_ID.out" "single_$JOB_ID.err" cp_average.txt cp_output.txt; do
    scp_run "$USER_HOST:$REMOTE_DIR/$f" "$LOCAL_OUT/" >/dev/null 2>&1 \
        || echo "  (não encontrei $f no cluster)"
done

echo
echo "== stdout do job =="
cat "$LOCAL_OUT/single_$JOB_ID.out" 2>/dev/null || true
echo
echo "== stderr do job (perf stat) =="
cat "$LOCAL_OUT/single_$JOB_ID.err" 2>/dev/null || true
if [[ -f "$LOCAL_OUT/cp_average.txt" ]]; then
    echo
    echo "== Médias (cp_average.txt) =="
    cat "$LOCAL_OUT/cp_average.txt"
fi

echo
echo "== Job terminado com estado: ${STATE:-desconhecido} =="
echo "Resultados em: single_$JOB_ID/"

if [[ -n "$STATE" && "$STATE" != COMPLETED* ]]; then
    echo "AVISO: o job não terminou com sucesso ($STATE). Limite de tempo: $TIME_LIMIT."
    exit 1
fi