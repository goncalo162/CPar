#!/bin/bash
# Valida o resultado do MD no Deucalion contra compare/reference.csv.
# Compila com o Makefile do cluster, corre 1 vez e compara T, P, PV/nT e Z.
#
# Uso (no Mac, na pasta CParTP):
#   ./valida.sh          # 48 threads
#   ./valida.sh 8        # outro nº de threads
#
# Usa o src/MD.cpp e o Makefile que estão NO CLUSTER (envia antes com upload_files.sh).

T="${1:-48}"
REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

ssh "$REMOTE" "cd $DIR && T=$T srun -A $ACCOUNT -p normal-arm -t 5 -N1 -n1 -c 48 bash -s" <<'REMOTO'
ml GCC >/dev/null 2>&1
echo "CFLAGS:  $(grep '^CFLAGS' Makefile)"
echo "threads: $T"
make -s clean >/dev/null 2>&1; make -s md || exit 1
OMP_NUM_THREADS=$T OMP_PROC_BIND=close OMP_PLACES=cores ./md < inputdata.txt > /dev/null
echo
echo "cp_average.txt: $(tail -1 cp_average.txt)"
echo
# cp_average: tempo T P PV/nT Z V N  -> colunas 2..5
tail -1 cp_average.txt | awk -F, -v ref=compare/reference.csv '
BEGIN {
  col["T (K)"]=2; col["P (Pa)"]=3; col["PV/nT (J/(mol K))"]=4; col["Z"]=5
  while ((getline line < ref) > 0) {
    split(line, f, ",")
    if (f[1] in col) { exp_[f[1]]=f[2]; tol[f[1]]=f[3] }
  }
}
{
  split($0, v, " ")
  ok = 1
  printf "%-20s %18s %18s %12s %12s  %s\n", "campo", "obtido", "esperado", "diferença", "tolerância", ""
  for (k in col) {
    got = v[col[k]]; d = got - exp_[k]; if (d < 0) d = -d
    st = (d <= tol[k]) ? "OK" : "FALHA"
    if (st == "FALHA") ok = 0
    printf "%-20s %18.5f %18.5f %12.6g %12.6g  %s\n", k, got, exp_[k], d, tol[k], st
  }
  print ""
  print (ok ? "==> VALIDAÇÃO OK" : "==> VALIDAÇÃO FALHOU")
}'
REMOTO
