
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Uso: $0 plots/perf_branch-misses.png"
    exit 1
fi

FILE="$1"

if [[ ! -f "$FILE" ]]; then
    echo "Erro: ficheiro não encontrado: $FILE"
    exit 1
fi

if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$FILE" >/dev/null 2>&1 &
elif command -v open >/dev/null 2>&1; then
    open "$FILE"
elif command -v display >/dev/null 2>&1; then
    display "$FILE" &
else
    echo "Não encontrei um visualizador de imagens."
    exit 1
fi