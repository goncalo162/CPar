#!/bin/bash
# perf annotate do computeAccelerations no Deucalion, trazido para o Mac.
# Uso (no Mac):  ./detail.sh <nome>   ->  cria <nome>.txt aqui
NOME="${1:?uso: ./detail.sh <nome>}"

REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

ssh "$REMOTE" "cd $DIR && NOME='$NOME' srun -A $ACCOUNT -p normal-arm -N1 -n1 -c 48 --exclusive bash -s" <<'REMOTO' || exit 1
ml GCC >/dev/null 2>&1
CF=$(sed -n 's/^CFLAGS *= *//p' Makefile)
KF=$(sed -n 's/^KERNEL_FLAGS *= *//p' Makefile)
KFILE=$(for f in src/*.c; do b=$(basename "$f" .c); grep -qE "\b$b\.(c|o)\b" Makefile && echo "$f"; done | head -1)
gcc $CF -g -x c -c src/MD.cpp -o a_MD.o && gcc $CF $KF -g -c "$KFILE" -o a_f.o && gcc $CF a_MD.o a_f.o -lm -o md_annot || exit 1
OMP_NUM_THREADS=48 OMP_PROC_BIND=close OMP_PLACES=cores perf record -e cycles -o a.data ./md_annot < inputdata.txt >/dev/null 2>&1
perf annotate -i a.data --stdio computeAccelerations._omp_fn.0 2>/dev/null > "$NOME.txt"
rm -f a_MD.o a_f.o md_annot a.data
REMOTO

scp "$REMOTE:$DIR/$NOME.txt" . && echo "== guardado em $NOME.txt"