#!/bin/bash
# Recolhe dados do MD no Deucalion para vários nº de threads e guarda TUDO num .txt no Mac.
#
# Uso (no Mac):
#   ./recolhe.sh                 # threads por defeito
#   ./recolhe.sh 8 16 48 96      # só estas
#
# Resultado: resultados/<data_hora>.txt  (no Mac)
#
# Para cada nº de threads faz 2 runs:
#   RUN 1 - perf stat  : tempo total + contadores (modo contagem, overhead ~0) -> usar para TEMPOS
#   RUN 2 - perf record: % do tempo por função (amostragem, tem overhead)      -> usar para %
#
# Usa o src/MD.cpp e o Makefile que estão NO CLUSTER: envia antes as tuas alterações
# (scripts/upload_files.sh src/MD.cpp Makefile).

THREADS="${*:-1 8 16 32 48 64 96 128 144 192}"

REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa
EVENTS=task-clock,cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,br_pred,br_mis_pred,fp_dp_fixed_ops_spec,fp_dp_scale_ops_spec

mkdir -p resultados
OUT="resultados/$(date +%Y%m%d_%H%M%S).txt"
echo "== a correr no Deucalion; tudo vai também para $OUT"

ssh "$REMOTE" "cd $DIR && THREADS='$THREADS' EVENTS='$EVENTS' OMP_SCHEDULE='${OMP_SCHEDULE:-}' \
  srun -A $ACCOUNT -p normal-arm -t 30 -N1 -n1 -c 48 bash -s" <<'REMOTO' | tee "$OUT"
ml GCC >/dev/null 2>&1
[ -z "$OMP_SCHEDULE" ] && unset OMP_SCHEDULE

echo "################ INFO"
echo "data:      $(date)"
echo "nó:        $(hostname)"
echo "gcc:       $(gcc --version | head -1)"
echo "threads:   $THREADS"
echo "schedule:  ${OMP_SCHEDULE:-(o que está no código)}"
echo "md5 src:   $(md5sum src/MD.cpp)"
echo "CFLAGS:    $(grep '^CFLAGS' Makefile)"

# binário para TEMPOS: exatamente o do Makefile
make -s clean >/dev/null 2>&1; make -s md || exit 1
# binário para %: mesmas flags + -g -fno-inline (cada função com o seu nome)
CF=$(sed -n 's/^CFLAGS *= *//p' Makefile)
gcc $CF -g -fno-inline -fno-omit-frame-pointer src/MD.cpp -lm -o md_prof || exit 1

export OMP_PROC_BIND=close OMP_PLACES=cores
for T in $THREADS; do
  export OMP_NUM_THREADS=$T
  echo
  echo "################ THREADS=$T"
  echo "======== RUN 1: perf stat (tempo total + contadores)"
  perf stat -e "$EVENTS" ./md < inputdata.txt > /dev/null 2> stat.tmp
  cat stat.tmp
  echo "======== RUN 2: perf record + report (% por função)"
  perf record -e cycles:u -F 1000 -o rec.data ./md_prof < inputdata.txt > /dev/null 2>&1
  perf report -i rec.data --stdio --no-children --sort dso,sym 2>/dev/null | grep -v '^#' | grep -v '^$'
done
rm -f stat.tmp rec.data rec.data.old md_prof
echo
echo "################ FIM"
REMOTO
echo "== guardado em $OUT"
