#!/bin/bash
set -euo pipefail

# Corre UMA run do md no cluster (job sbatch de 2 minutos) e mostra o resultado.
# Com --report/--r faz 'make clean; make md && make runRecord' e copia o perf.data
# + binários (perf archive) para o teu computador (x86), abrindo 'perf report -n'
# com o disassembly ARM64 correto (annotate via objdump aarch64).
#
# Requisitos locais para --report (EndeavourOS / Arch):
#   sudo pacman -S --needed perf aarch64-linux-gnu-binutils
#
# Uso:
#   scripts/run_single.sh               # compila (make md) e corre (make runTest)
#   scripts/run_single.sh --u           # envia primeiro os ficheiros (scripts/upload_files.sh)
#   scripts/run_single.sh --report      # corre make runRecord e copia perf.data + binários
#   scripts/run_single.sh --u --report  # envia os ficheiros e depois corre make runRecord
#   THREADS=16 scripts/run_single.sh    # nº de threads (por defeito 48)
#   OBJDUMP=/caminho/aarch64-linux-gnu-objdump scripts/run_single.sh --report   # força o objdump
#
# Resultados em single_<JOBID>/ (modo run) ou report_<JOBID>/ (modo report).

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
OBJDUMP="${OBJDUMP:-}"   # objdump aarch64 (auto-detetado em --report se vazio)

# ---- argumentos ----
UPDATE=0
REPORT=0
for arg in "$@"; do
    case "$arg" in
        --u|-u|--update) UPDATE=1 ;;
        --r|-r|--record|--report) REPORT=1 ;;
        -h|--help)
            echo "Uso: $0 [--u] [--report|--r]"
            echo "  --u, --update   envia os ficheiros para o cluster antes de correr"
            echo "  --r, --report   corre 'make runRecord' no cluster e copia perf.data + binários"
            echo "  OBJDUMP=...     objdump aarch64 (por defeito procura aarch64-linux-gnu-objdump)"
            exit 0 ;;
        *)
            echo "Argumento desconhecido: $arg (usa --u, --report ou --help)" >&2
            exit 1 ;;
    esac
done

if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Erro: THREADS inválido: $THREADS" >&2
    exit 1
fi

# ============================================================
# Pré-verificação local do modo report (antes de gastar tempo no cluster)
# ============================================================
if (( REPORT )); then
    command -v perf >/dev/null || {
        echo "Erro: 'perf' não está instalado nesta máquina." >&2
        echo "      sudo pacman -S --needed perf aarch64-linux-gnu-binutils" >&2
        exit 1
    }

    # Em máquinas não-ARM é preciso um objdump que perceba AArch64
    if [[ -z "$OBJDUMP" && "$(uname -m)" != aarch64 ]]; then
        for cand in aarch64-linux-gnu-objdump aarch64-none-linux-gnu-objdump aarch64-unknown-linux-gnu-objdump; do
            if command -v "$cand" >/dev/null 2>&1; then
                OBJDUMP="$(command -v "$cand")"
                break
            fi
        done
    fi

    if [[ -z "$OBJDUMP" && "$(uname -m)" != aarch64 ]]; then
        echo "Erro: não encontrei um objdump AArch64 (necessário para o annotate de código ARM)." >&2
        echo "      sudo pacman -S --needed aarch64-linux-gnu-binutils" >&2
        exit 1
    fi

    if [[ -n "$OBJDUMP" ]]; then
        command -v "$OBJDUMP" >/dev/null 2>&1 || { echo "Erro: OBJDUMP='$OBJDUMP' não existe." >&2; exit 1; }
        case "$OBJDUMP" in
            *llvm-objdump*) ;;
            *)
                "$OBJDUMP" -i 2>&1 | grep -qi aarch64 || {
                    echo "Erro: '$OBJDUMP' não suporta AArch64 (um objdump x86 mostraria lixo)." >&2
                    exit 1
                } ;;
        esac
        echo "objdump para annotate: $OBJDUMP"
    fi
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
# 1. Submeter o job
# ============================================================
if (( REPORT )); then
    JOB_NAME="md_report"
    OUT_PREFIX="report"
    # 'make runRecord' invoca 'perf record -F 1000 -g ./md < inputdata.txt' -> perf.data.
    # Depois 'perf archive' empacota os binários (md, libc, libgomp...) com os build-ids,
    # para o perf local resolver símbolos e disassembly ARM64.
    JOB_CMD="ml GCC; make clean; $OMP_ENV OMP_NUM_THREADS=$THREADS make runRecord && perf archive perf.data || true"
    JOB_DESC="relatório (perf record)"
else
    JOB_NAME="md_single"
    OUT_PREFIX="single"
    JOB_CMD="ml GCC; make clean; make md && $OMP_ENV OMP_NUM_THREADS=$THREADS make runTest"
    JOB_DESC="run"
fi

echo "== A submeter o $JOB_DESC (limite $TIME_LIMIT, $THREADS threads) =="
JOB_ID=$(ssh_run "cd '$REMOTE_DIR' && sbatch --parsable -J $JOB_NAME -A $ACCOUNT -p $PARTITION -t $TIME_LIMIT --nodes=1 --ntasks=1 --cpus-per-task=$CPUS -o ${OUT_PREFIX}_%j.out -e ${OUT_PREFIX}_%j.err --wrap '$JOB_CMD'" \
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
LOCAL_OUT="$ROOT/${OUT_PREFIX}_$JOB_ID"
mkdir -p "$LOCAL_OUT"

# Logs do job (sempre)
for f in "${OUT_PREFIX}_$JOB_ID.out" "${OUT_PREFIX}_$JOB_ID.err"; do
    scp_run "$USER_HOST:$REMOTE_DIR/$f" "$LOCAL_OUT/" >/dev/null 2>&1 \
        || echo "  (não encontrei $f no cluster)"
done

# Dados específicos do modo
if (( REPORT )); then
    if scp_run "$USER_HOST:$REMOTE_DIR/perf.data" "$LOCAL_OUT/" >/dev/null 2>&1; then
        echo "== perf.data copiado: $LOCAL_OUT/perf.data =="
    else
        echo "  (não encontrei perf.data no cluster)"
    fi

    # ---- Binários: perf archive cria perf.data.tar.bz2 com os binários ----
    #      (md + libc + libgomp..., identificados pelos build-ids do perf.data)
    if scp_run "$USER_HOST:$REMOTE_DIR/perf.data.tar.bz2" "$LOCAL_OUT/" >/dev/null 2>&1; then
        echo "== Binários empacotados: $LOCAL_OUT/perf.data.tar.bz2 =="
        # Extrai para a build-id cache do perf (~/.debug) -> resolve os símbolos
        mkdir -p "$HOME/.debug"
        tar xf "$LOCAL_OUT/perf.data.tar.bz2" -C "$HOME/.debug" \
            && echo "   Símbolos instalados em ~/.debug (build-id cache do perf)"
        # Cópia do binário md também na pasta do report, para referência/objdump
        scp_run "$USER_HOST:$REMOTE_DIR/md" "$LOCAL_OUT/" >/dev/null 2>&1 \
            || echo "  (não consegui copiar o binário md)"
                # Sem build-id no md o perf não o encontra -> endereços crus em vez de símbolos
        if [[ -f "$LOCAL_OUT/md" ]] && command -v readelf >/dev/null 2>&1; then
            readelf -n "$LOCAL_OUT/md" 2>/dev/null | grep -q "Build ID" \
                || echo "  AVISO: o md não tem build-id (recompila com 'make clean; make md' usando o Makefile novo)."
        fi
    else
        echo "  (perf.data.tar.bz2 não existe — o perf archive falhou no cluster?)"
    fi
else
    for f in cp_average.txt cp_output.txt bus_counters.txt; do
        scp_run "$USER_HOST:$REMOTE_DIR/$f" "$LOCAL_OUT/" >/dev/null 2>&1 \
            || echo "  (não encontrei $f no cluster)"
    done
fi

echo
echo "== stdout do job =="
cat "$LOCAL_OUT/${OUT_PREFIX}_$JOB_ID.out" 2>/dev/null || true
echo
echo "== stderr do job =="
cat "$LOCAL_OUT/${OUT_PREFIX}_$JOB_ID.err" 2>/dev/null || true

if ! (( REPORT )) && [[ -f "$LOCAL_OUT/cp_average.txt" ]]; then
    echo
    echo "== Médias (cp_average.txt) =="
    cat "$LOCAL_OUT/cp_average.txt"
fi

echo
echo "== Job terminado com estado: ${STATE:-desconhecido} =="
echo "Resultados em: ${OUT_PREFIX}_$JOB_ID/"

if [[ -n "$STATE" && "$STATE" != COMPLETED* ]]; then
    echo "AVISO: o job não terminou com sucesso ($STATE). Limite de tempo: $TIME_LIMIT."
    exit 1
fi

# ============================================================
# 4. Modo report: abrir perf report -n com símbolos e annotate ARM64 corretos
# ============================================================
if (( REPORT )) && [[ -f "$LOCAL_OUT/perf.data" ]]; then
    REPORT_ARGS=(-n --no-children -i "$LOCAL_OUT/perf.data" --sort symbol,dso)
    if [[ -n "$OBJDUMP" ]]; then
        REPORT_ARGS+=(--objdump "$OBJDUMP")   # annotate (tecla 'a') desmonta AArch64 na tua máquina
        echo
        echo "Dica: dentro do perf report, Annotate (tecla 'a') usa '$OBJDUMP'"
    fi
    echo
    echo "== A abrir perf report -n (Ctrl+q para sair) =="
    perf report "${REPORT_ARGS[@]}" || {
        echo "perf report falhou. Tenta manualmente:"
        echo "  perf report -n -i '$LOCAL_OUT/perf.data' --objdump '${OBJDUMP:-objdump}'"
    }
fi