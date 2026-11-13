#!/bin/bash
# Valida o cp_average.txt (médias finais, como o 1.º teste do Gonçalo) contra os valores
# esperados de compare/reference.csv, mas com regra de CASAS DECIMAIS em vez das tolerâncias
# escritas à mão:
#
#   x = nº de casas decimais com que o valor é impresso (o menor entre obtido e esperado)
#   - se x >= 12  -> exige igualdade até 12 casas decimais:   |obtido - esperado| <= 1e-12
#   - se x <  12  -> exige igualdade até x-1 casas decimais:  |obtido - esperado| <= 10^-(x-1)
#   - em notação científica (ex.: 2.37220e-25) as casas contam na mantissa e a tolerância
#     é escalada pelo expoente;  inteiros (x = 0, ex.: N) têm de ser exatamente iguais.
#
# A coluna "tolerance" do reference.csv é ignorada (só se usa a "expected").
#
# Uso (no Mac, na pasta CParTP):
#   ./valida_casas.sh          # threads do benchmark do Gonçalo: 1 8 16 32 48 64 96 128 144 192
#   ./valida_casas.sh 48       # só esse nº de threads
#   ./valida_casas.sh 8 48     # só estes
#
# Usa o src/MD.cpp e o Makefile que estão NO CLUSTER (envia antes com upload_files.sh).

THREADS="${*:-1 8 16 32 48 64 96 128 144 192}"
REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

ssh "$REMOTE" "cd $DIR && THREADS='$THREADS' srun -A $ACCOUNT -p normal-arm -t 15 -N1 -n1 -c 48 bash -s" <<'REMOTO'
ml GCC >/dev/null 2>&1
echo "CFLAGS:  $(grep '^CFLAGS' Makefile)"
echo "threads: $THREADS"
make -s clean >/dev/null 2>&1; make -s md || exit 1

cat > valida_casas.py <<'PY'
import csv, sys
from decimal import Decimal

avg_file, ref_file = sys.argv[1:3]
MAX_CASAS = 12

# colunas do cp_average.txt (última linha com 7 valores)
names = ["Total Time (s)", "T (K)", "P (Pa)", "PV/nT (J/(mol K))", "Z", "V (m^3)", "N"]
tokens = None
for line in open(avg_file, errors="replace"):
    t = line.split()
    if len(t) == 7:
        try:
            [float(x) for x in t]
            tokens = t
        except ValueError:
            pass
if tokens is None:
    sys.exit("ERRO: não encontrei a linha de médias no cp_average.txt")
got = dict(zip(names, tokens))

ref = {}
for row in csv.DictReader(open(ref_file, newline="")):
    ref[row["field"].strip()] = row["expected"].strip()

def casas(s):
    """(casas decimais, expoente) tal como o número está escrito."""
    s = s.lower().lstrip("+-")
    exp = 0
    if "e" in s:
        s, e = s.split("e")
        exp = int(e)
    dec = len(s.split(".")[1]) if "." in s else 0
    return dec, exp

ok = True
print(f"{'campo':20} {'obtido':>18} {'esperado':>18} {'casas':>5} {'exige':>5} {'diferença':>11} {'tolerância':>11}")
for name in names:
    if name not in ref:
        continue
    g, r = got[name], ref[name]
    cg, eg = casas(g)
    cr, er = casas(r)
    x = min(cg, cr)
    exige = MAX_CASAS if x >= MAX_CASAS else max(x - 1, 0)
    # tolerância: 10^-(casas exigidas), escalada pelo expoente em notação científica
    if x == 0:
        tol = Decimal(0)                      # inteiro: igualdade exata
    else:
        tol = Decimal(1).scaleb(-exige + min(eg, er))
    diff = abs(Decimal(g) - Decimal(r))
    st = "OK" if diff <= tol else "FALHA"
    ok &= st == "OK"
    print(f"{name:20} {g:>18} {r:>18} {x:>5} {exige:>5} {float(diff):>11.3e} {float(tol):>11.1e}  {st}")

print()
print("==> VALIDAÇÃO OK" if ok else "==> VALIDAÇÃO FALHOU")
sys.exit(0 if ok else 1)
PY

FALHAS=""
for T in $THREADS; do
  echo
  echo "################ THREADS=$T"
  OMP_NUM_THREADS=$T OMP_PROC_BIND=close OMP_PLACES=cores ./md < inputdata.txt > /dev/null
  echo "cp_average.txt: $(tail -1 cp_average.txt)"
  python3 valida_casas.py cp_average.txt compare/reference.csv || FALHAS="$FALHAS $T"
done
rm -f valida_casas.py

echo
echo "################ RESUMO"
if [ -z "$FALHAS" ]; then
  echo "Todas as corridas passaram ($THREADS)."
else
  echo "Falharam as corridas com threads:$FALHAS"
fi
REMOTO
