#!/bin/bash
set -euo pipefail

# Envia ficheiros para REMOTE_DIR no cluster (password pedida uma única vez).
#
# Uso:
#   scripts/upload_files.sh                      # envia DEFAULT_FILES
#   scripts/upload_files.sh src/MD.cpp Makefile  # envia só estes
#   scripts/upload_files.sh --close              # fecha a ligação SSH partilhada
#
# Cada entrada é "local" ou "local:remoto" (relativos à raiz do projeto e a
# REMOTE_DIR). Sem ":", o caminho remoto é igual ao local.

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

DEFAULT_FILES=(
    "src/MD.cpp"
    "src/forces.c"
    "src/newton.c"
    "src/md.h"
    "Makefile"
    "scripts/benchmark.sh"
)

if [[ "${1:-}" == "--close" ]]; then
    ssh "${SSH_OPTS[@]}" -O exit "$USER_HOST" 2>/dev/null && echo "Ligação SSH fechada." \
        || echo "Não havia ligação SSH aberta."
    exit 0
fi

FILES=("$@")
(( ${#FILES[@]} )) || FILES=("${DEFAULT_FILES[@]}")

# validar que todos os ficheiros locais existem antes de enviar
missing=0
for entry in "${FILES[@]}"; do
    src="${entry%%:*}"
    [[ -f "$ROOT/$src" ]] || { echo "Erro: ficheiro local em falta: $ROOT/$src" >&2; missing=1; }
done
(( missing == 0 )) || exit 1

ensure_connection

# criar pastas remotas
mkdirs=""
for entry in "${FILES[@]}"; do
    mkdirs+=" '$REMOTE_DIR/$(dirname "${entry#*:}")'"
done
ssh_run "mkdir -p $mkdirs"

# enviar (-p preserva permissões e datas)
for entry in "${FILES[@]}"; do
    src="${entry%%:*}"; dst="${entry#*:}"
    echo "  $src  ->  $REMOTE_DIR/$dst"
    scp_run -p "$ROOT/$src" "$USER_HOST:$REMOTE_DIR/$dst"
done
echo "Envio concluído (${#FILES[@]} ficheiro(s))."