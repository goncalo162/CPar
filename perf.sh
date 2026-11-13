#!/bin/bash
# Perfil com perf do MD: tempo total + % do tempo por função.
#
# Uso (no Mac, na pasta onde está este script, ou já no Deucalion):
#   ./perf.sh single   -> 1 thread, sequencial puro (compila sem -fopenmp, -O2)
#   ./perf.sh par      -> 48 threads (flags do Makefile: -O3 -ffast-math -fopenmp)
#
# No Mac (sem srun) liga-se sozinho ao Deucalion por ssh e corre lá, na pasta DIR.
# Compila sempre com -fno-inline para cada função aparecer com o seu nome.

MODE="${1:-}"
case "$MODE" in
  single|par) ;;
  *) echo "uso: ./perf.sh single | par"; exit 1 ;;
esac

REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

# No Mac: reenviar este script para o Deucalion e corrê-lo lá
if ! command -v srun >/dev/null 2>&1; then
  exec ssh "$REMOTE" "cd $DIR && bash -s -- $MODE" < "$0"
fi

if [ "$MODE" = single ]; then
  CPUS=1;  FLAGS="-O2"
else
  CPUS=48; FLAGS="-O3 -ffast-math -fopenmp"
fi
export MODE CPUS FLAGS

echo "== modo: $MODE | threads: $CPUS | flags: $FLAGS -g -fno-inline"
echo "== a pedir nó ARM (máx. 10 min)..."

srun -A "$ACCOUNT" -p normal-arm -t 10 -N1 -n1 -c "$CPUS" bash -c '
  ml GCC >/dev/null 2>&1
  gcc -x c $FLAGS -g -fno-inline -fno-omit-frame-pointer src/MD.cpp -lm -o md_perf || exit 1

  export OMP_NUM_THREADS=$CPUS OMP_PROC_BIND=close OMP_PLACES=cores

  echo
  echo "== tempo total (linha real)"
  { time perf record -q -F 2000 -o perf_$MODE.data ./md_perf < inputdata.txt > /dev/null; } 2>&1

  echo
  echo "== % do tempo por função  (Overhead | ficheiro | função)"
  perf report -i perf_$MODE.data --stdio --no-children --sort dso,sym 2>/dev/null \
    | grep "%" | grep -v "^#" | head -30
'
