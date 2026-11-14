#!/bin/bash
# Recolhe dados do MD no Deucalion para vários nº de threads e guarda TUDO num .txt no Mac.
#
# Uso (no Mac):
#   ./recolhe.sh                 # threads por defeito
#   ./recolhe.sh 8 16 48 96      # só estas
#
# Resultado: resultados/<data_hora>.txt  (no Mac)
#
# Para cada nº de threads:
#   RUN 1 - perf stat x NRUNS (10): média, melhor, pior, mediana + contadores da run mediana
#   RUN 2 - perf record: % do tempo por função (amostragem, tem overhead)      -> usar para %
#
# Usa o src/MD.cpp e o Makefile que estão NO CLUSTER: envia antes as tuas alterações
# (scripts/upload_files.sh src/MD.cpp Makefile).

THREADS="${*:-1 8 16 32 48 64 96 128 144 192}"
NRUNS="${NRUNS:-10}"   # nº de runs do perf stat por nº de threads (NRUNS=5 ./recolhe.sh 48)

REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa
EVENTS=task-clock,cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,br_pred,br_mis_pred,fp_dp_fixed_ops_spec,fp_dp_scale_ops_spec

mkdir -p resultados
OUT="resultados/$(date +%Y%m%d_%H%M%S).txt"
echo "== a correr no Deucalion; tudo vai também para $OUT"

ssh "$REMOTE" "cd $DIR && THREADS='$THREADS' NRUNS='$NRUNS' EVENTS='$EVENTS' OMP_SCHEDULE='${OMP_SCHEDULE:-}' \
  srun -A $ACCOUNT -p normal-arm -t 30 -N1 -n1 -c 48 bash -s" <<'REMOTO' | tee "$OUT"
ml GCC >/dev/null 2>&1
[ -z "$OMP_SCHEDULE" ] && unset OMP_SCHEDULE

echo "################ INFO"
echo "data:      $(date)"
echo "nó:        $(hostname)"
echo "gcc:       $(gcc --version | head -1)"
echo "threads:   $THREADS"
echo "schedule:  ${OMP_SCHEDULE:-(o que está no código)}"
echo "md5 src:   $(md5sum src/MD.cpp src/*.c 2>/dev/null | tr '\n' ' ')"
echo "CFLAGS:    $(grep '^CFLAGS' Makefile)"
echo "KERNEL:    $(grep '^KERNEL_FLAGS' Makefile)"

# binário para TEMPOS: exatamente o do Makefile
make -s clean >/dev/null 2>&1; make -s md || exit 1
# binário para %: mesmas flags + -g -fno-inline (cada função com o seu nome)
CF=$(sed -n 's/^CFLAGS *= *//p' Makefile)
KF=$(sed -n 's/^KERNEL_FLAGS *= *//p' Makefile)
PF="-g -fno-inline -fno-omit-frame-pointer"
KFILE=$(for f in src/*.c; do b=$(basename "$f" .c); grep -qE "\b$b\.(c|o)\b" Makefile && echo "$f"; done | head -1)
if [ -n "$KFILE" ]; then
  # kernels no ficheiro que o Makefile compila (forces.c, newton.c, ...), com KERNEL_FLAGS
  echo "kernel:    $KFILE"
  gcc $CF $PF -x c -c src/MD.cpp -o prof_MD.o || exit 1
  gcc $CF $KF $PF -c "$KFILE" -o prof_forces.o || exit 1
  gcc $CF prof_MD.o prof_forces.o -lm -o md_prof || exit 1
  rm -f prof_MD.o prof_forces.o
else
  gcc $CF $PF src/MD.cpp -lm -o md_prof || exit 1
fi

export OMP_PROC_BIND=close OMP_PLACES=cores
for T in $THREADS; do
  export OMP_NUM_THREADS=$T
  echo
  echo "################ THREADS=$T"
  echo "======== RUN 1: perf stat x $NRUNS (tempo total + contadores)"
  rm -f tempos.tmp
  for r in $(seq 1 $NRUNS); do
    perf stat -e "$EVENTS" ./md < inputdata.txt > /dev/null 2> stat_$r.tmp
    t=$(awk '/seconds time elapsed/{print $1}' stat_$r.tmp)
    echo "$r $t" >> tempos.tmp
    echo "  run $r: $t s"
  done
  # média, melhor, pior e mediana dos tempos
  sort -k2 -g tempos.tmp | awk -v n=$NRUNS '
    {id[NR]=$1; t[NR]=$2; s+=$2}
    END {
      if (n % 2) med = t[(n+1)/2]; else med = (t[n/2] + t[n/2+1]) / 2;
      printf "  média:   %.4f s\n  melhor:  %.4f s\n  pior:    %.4f s\n  mediana: %.4f s\n", s/n, t[1], t[n], med;
      print id[int((n+1)/2)] > "med_id.tmp"
    }'
  MED=$(cat med_id.tmp)
  echo "--- contadores da run mediana (run $MED):"
  cat stat_$MED.tmp
  rm -f stat_*.tmp tempos.tmp med_id.tmp
  echo "======== RUN 2: perf record + report (% por função)"
  perf record -e cycles:u -F 1000 -o rec.data ./md_prof < inputdata.txt > /dev/null 2>&1
  perf report -i rec.data --stdio --no-children --sort dso,sym 2>/dev/null | grep -v '^#' | grep -v '^$'
done
rm -f stat.tmp rec.data rec.data.old md_prof
echo
echo "################ FIM"
REMOTO
echo "== guardado em $OUT"
