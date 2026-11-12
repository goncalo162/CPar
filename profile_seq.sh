#!/bin/bash
#SBATCH -A f202500010hpcvlabuminhoa
#SBATCH -p normal-arm
#SBATCH -t 10:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --output=prof.o%j
#SBATCH --error=prof.e%j

SRC="${1:-src/MD.cpp}"
PFLAGS="${PFLAGS:--O2}"

ml GCC
echo "== Fonte: $SRC | flags: $PFLAGS -g -pg -fno-inline"
gcc -x c $PFLAGS -g -pg -fno-inline "$SRC" -lm -o md_prof || exit 1

export OMP_NUM_THREADS=1
rm -f gmon.out
echo "== Tempo total (1 thread)"
/usr/bin/time -p ./md_prof < inputdata.txt > /dev/null

echo
echo "== Perfil por função (gprof, flat profile)"
echo "   % time = percentagem do tempo total | self seconds = tempo dentro da função"
gprof -b -p ./md_prof gmon.out
