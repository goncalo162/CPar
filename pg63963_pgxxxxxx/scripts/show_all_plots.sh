
#!/usr/bin/env bash
set -euo pipefail

DIR="${1:-plots}"

if [[ ! -d "$DIR" ]]; then
    echo "Erro: pasta não encontrada: $DIR"
    exit 1
fi

shopt -s nullglob
FILES=("$DIR"/*.png)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Não foram encontrados gráficos PNG em $DIR"
    exit 1
fi

if command -v feh >/dev/null 2>&1; then
    feh "${FILES[@]}" &
elif command -v xdg-open >/dev/null 2>&1; then
    for FILE in "${FILES[@]}"; do
        xdg-open "$FILE" >/dev/null 2>&1 &
    done
elif command -v open >/dev/null 2>&1; then
    for FILE in "${FILES[@]}"; do
        open "$FILE"
    done
elif command -v display >/dev/null 2>&1; then
    display "${FILES[@]}" &
else
    echo "Não encontrei um visualizador de imagens."
    exit 1
fi