#!/bin/bash
# Mede o tempo de parede de CADA região paralela do MD (com omp_get_wtime) para perceber
# de onde vem o tempo perdido em barreiras/sincronização.
#
# Não mexe no teu código: no cluster copia src/, Makefile e inputdata.txt para uma pasta
# temporária, mete lá os temporizadores, compila com o teu Makefile, corre e apaga a pasta.
#
# Uso (no Mac, na pasta CParTP):
#   ./regioes.sh            # 1 e 48 threads
#   ./regioes.sh 1 8 48     # outros (inclui sempre o 1, é a referência da eficiência)
#
# Usa o src/ e o Makefile que estão NO CLUSTER (envia antes com upload_files.sh).

THREADS="${*:-1 48}"
case " $THREADS " in *" 1 "*) ;; *) THREADS="1 $THREADS" ;; esac
REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

ssh "$REMOTE" "cd $DIR && THREADS='$THREADS' srun -A $ACCOUNT -p normal-arm -t 10 -N1 -n1 -c 48 bash -s" <<'REMOTO'
ml GCC >/dev/null 2>&1
W=$(mktemp -d "$PWD/regioes_tmp.XXXX") || exit 1
cp -r src Makefile inputdata.txt "$W"/ && cd "$W" || exit 1

cat > instr.py <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
def sub(old, new):
    global s
    if s.count(old) != 1:
        sys.exit("instr: padrao nao encontrado 1x: " + old[:40])
    s = s.replace(old, new)
sub('#include "md.h"\n', '#include "md.h"\nstatic double T_LOOP, T_VV, T_ACC, T_MSV, T_KIN, T_POT;\n')
sub('    computeAccelerations();\n\n/* Segunda',
    '    { double t_ = omp_get_wtime(); computeAccelerations(); T_ACC += omp_get_wtime() - t_; }\n\n/* Segunda')
sub('    for (i = 0; i < NumTime + 1; i++)\n',
    '    double t_loop0 = omp_get_wtime();\n    for (i = 0; i < NumTime + 1; i++)\n')
sub('        Press = VelocityVerlet(dt, i + 1, tfp) * PressFac;\n        mvs = MeanSquaredVelocity();\n        KE = Kinetic();\n        PE = Potential();\n',
    '        double t_ = omp_get_wtime();\n'
    '        Press = VelocityVerlet(dt, i + 1, tfp) * PressFac;\n'
    '        T_VV += omp_get_wtime() - t_; t_ = omp_get_wtime();\n'
    '        mvs = MeanSquaredVelocity();\n'
    '        T_MSV += omp_get_wtime() - t_; t_ = omp_get_wtime();\n'
    '        KE = Kinetic();\n'
    '        T_KIN += omp_get_wtime() - t_; t_ = omp_get_wtime();\n'
    '        PE = Potential();\n'
    '        T_POT += omp_get_wtime() - t_;\n')
sub('    Pavg /= NumTime;\n', '    T_LOOP = omp_get_wtime() - t_loop0;\n    Pavg /= NumTime;\n')
sub('    fclose(tfp);\n    fclose(ofp);\n    fclose(afp);\n    return EXIT_SUCCESS;',
    '    fprintf(stderr, "REGIOES %.6f %.6f %.6f %.6f %.6f %.6f\\n", T_LOOP, T_VV, T_ACC, T_MSV, T_KIN, T_POT);\n'
    '    fclose(tfp);\n    fclose(ofp);\n    fclose(afp);\n    return EXIT_SUCCESS;')
open(p, 'w').write(s)
PY
python3 instr.py src/MD.cpp || exit 1
make -s md >/dev/null || { echo "ERRO de compilação"; exit 1; }

echo "threads: $THREADS"
for T in $THREADS; do
  echo -n "$T " >> tempos.txt
  OMP_NUM_THREADS=$T OMP_PROC_BIND=close OMP_PLACES=cores ./md < inputdata.txt 2>&1 >/dev/null \
    | grep '^REGIOES' | cut -d' ' -f2- >> tempos.txt
done

python3 - tempos.txt <<'PY'
import sys
rows = {}
for line in open(sys.argv[1]):
    t = line.split()
    if len(t) == 7:
        rows[int(t[0])] = [float(x) for x in t[1:]]
def regs(v):
    loop, vv, acc, msv, kin, pot = v
    return [("VelocityVerlet (2 ciclos O(N))", vv - acc), ("computeAccelerations", acc),
            ("MeanSquaredVelocity", msv), ("Kinetic", kin), ("Potential", pot),
            ("resto (série, I/O)", loop - vv - msv - kin - pot), ("TOTAL (ciclo principal)", loop)]
base = dict(regs(rows[1]))
for n in sorted(rows):
    if n == 1:
        continue
    print(f"\n################ {n} threads  (referência: 1 thread)")
    print(f"{'região':32} {'T1 (s)':>8} {'TN (s)':>8} {'% de TN':>8} {'speedup':>8} {'efic.':>6} {'perda (s)':>10}")
    tot = rows[n][0]
    for name, tn in regs(rows[n]):
        t1 = base[name]
        sp = t1 / tn if tn > 0 else 0
        print(f"{name:32} {t1:8.4f} {tn:8.4f} {100*tn/tot:7.1f}% {sp:7.1f}x {100*sp/n:5.0f}% {tn - t1/n:10.4f}")
print("\nperda = TN - T1/N: tempo a mais do que o ideal (barreiras, desequilíbrio, fork/join).")
PY
cd .. && rm -rf "$W"
REMOTO
