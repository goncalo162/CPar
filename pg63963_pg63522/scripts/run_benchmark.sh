#!/bin/bash
set -euo pipefail

# Uso:
#   scripts/run_benchmark.sh        # corre o benchmark completo
#   scripts/run_benchmark.sh --u    # envia primeiro os ficheiros (scripts/upload_files.sh)

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

BENCH_SCRIPT="scripts/benchmark.sh"
LOCAL_DIR="."
POLL_INTERVAL=60    # segundos entre verificações do estado do job

# ============================================================
# 0. Abrir a ligação SSH (única vez em que pede a password) e update opcional
# ============================================================
ensure_connection

if (( UPDATE )); then
    echo "== A atualizar os ficheiros no cluster (--u) =="
    bash "$ROOT/scripts/upload_files.sh"
fi

# ============================================================
# 1. Submeter o job
# ============================================================
echo "== A submeter o benchmark no cluster =="
JOB_ID=$(ssh_run "quotaprojects >&2; cd '$REMOTE_DIR' && sbatch --parsable $BENCH_SCRIPT" \
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
    STATE=$(ssh_run "squeue --job $JOB_ID --noheader --format=%T 2>/dev/null" || true)
    if [[ -z "$STATE" ]]; then
        break
    fi
    echo "  Estado: $STATE ($(date +%H:%M:%S))"
    sleep "$POLL_INTERVAL"
done

STATE=$(ssh_run "sacct -j $JOB_ID --noheader --format=State | head -n1 | xargs" || true)
echo "== Job terminado com estado: ${STATE:-desconhecido} =="

if [[ "$STATE" == "FAILED" || "$STATE" == "TIMEOUT" || "$STATE" == "CANCELLED"* ]]; then
    echo "AVISO: o job não terminou com sucesso ($STATE)."
    echo "Vou copiar os logs out.o$JOB_ID / err.e$JOB_ID para inspecionares."
    scp_run -r "$USER_HOST:$REMOTE_DIR/benchmark_$JOB_ID" "$LOCAL_DIR/" 2>/dev/null || true
    scp_run "$USER_HOST:$REMOTE_DIR/out.o$JOB_ID" "$USER_HOST:$REMOTE_DIR/err.e$JOB_ID" "$LOCAL_DIR/" 2>/dev/null || true
    exit 1
fi

# ============================================================
# 3. Copiar os resultados
# ============================================================
echo "== A copiar benchmark_$JOB_ID para a tua máquina =="
scp_run -r "$USER_HOST:$REMOTE_DIR/benchmark_$JOB_ID" "$LOCAL_DIR/benchmark_$JOB_ID"

# ============================================================
# 4. Gerar os plots
# ============================================================
echo "== A gerar os plots =="
mkdir -p plots
gnuplot -e "csvfile='benchmark_$JOB_ID/results.csv'; outdir='plots'" scripts/plot_result.gp

echo
echo "== Concluído =="
echo "Resultados:   benchmark_$JOB_ID/"
echo "Plots:       plots/"
echo "Estado do job: $STATE"