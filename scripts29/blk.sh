#!/bin/bash
# Varre o tamanho do bloco (BLK) da fissão em src/forces.c, sempre com 48 threads.
# Para cada BLK: recompila com -DBLK=<valor> e corre 3 vezes; mostra a mediana e o mínimo.
#
# Não mexe no teu código: no cluster copia src/, Makefile e inputdata.txt para uma pasta
# temporária, compila lá (make -B md KERNEL_FLAGS=...) e apaga a pasta no fim.
#
# Uso (no Mac, na pasta CParTP):
#   ./blk.sh                      # 4 8 16 32 64 128 256 512 1024 2048
#   ./blk.sh "256 512 1024"       # outros valores
#
# Usa o src/ e o Makefile que estão NO CLUSTER (envia antes com upload_files.sh).

BLKS="${1:-4 8 16 32 64 128 256 512 1024 2048}"
REPS=3
REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

ssh "$REMOTE" "cd $DIR && BLKS='$BLKS' REPS=$REPS srun -A $ACCOUNT -p normal-arm -t 15 -N1 -n1 -c 48 bash -s" <<'REMOTO'
ml GCC >/dev/null 2>&1
W=$(mktemp -d "$PWD/blk_tmp.XXXX") || exit 1
cp -r src Makefile inputdata.txt "$W"/ && cd "$W" || exit 1
grep -q "BLK" src/forces.c || { echo "ERRO: src/forces.c não tem BLK (não é a versão com fissão)"; exit 1; }

export OMP_NUM_THREADS=48 OMP_PROC_BIND=close OMP_PLACES=cores
echo "== 48 threads, $REPS corridas por BLK (mediana / mínimo)"
for B in $BLKS; do
  make -s -B md KERNEL_FLAGS="-mlow-precision-div -DBLK=$B" >/dev/null 2>&1 \
    || { echo "BLK $B -> ERRO de compilação"; continue; }
  ts=""
  for r in $(seq $REPS); do
    s=$(date +%s.%N); ./md < inputdata.txt > /dev/null 2>&1; e=$(date +%s.%N)
    ts="$ts $(awk -v a=$s -v b=$e 'BEGIN{printf "%.6f", b-a}')"
  done
  echo $ts | tr ' ' '\n' | sort -n | awk -v b=$B '{v[NR]=$1} END {printf "BLK %-5s -> %.4f s   (mín %.4f s)\n", b, v[int((NR+1)/2)], v[1]}'
done
cd .. && rm -rf "$W"
REMOTO
