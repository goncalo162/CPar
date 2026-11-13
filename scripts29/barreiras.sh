#!/bin/bash
# De onde vem o tempo das barreiras? Mede, em cada região paralela e para cada thread:
#   arranque (fork) + trabalho + espera na barreira do fim = tempo da região
# e o tempo fora das regiões (só a master trabalha, os workers estão parados).
#
# Não mexe no teu código: no cluster copia src/, Makefile e inputdata.txt para uma pasta
# temporária, troca cada "parallel for" por "parallel { for nowait }" com omp_get_wtime
# (mesmo cálculo, mesmo schedule), compila com o teu Makefile, corre e apaga a pasta.
#
# Uso (no Mac, na pasta CParTP):
#   ./barreiras.sh          # 48 threads
#   ./barreiras.sh 24 48    # outros nº de threads
#
# Usa o src/ e o Makefile que estão NO CLUSTER (envia antes com upload_files.sh).

THREADS="${*:-48}"
REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

ssh "$REMOTE" "cd $DIR && THREADS='$THREADS' srun -A $ACCOUNT -p normal-arm -t 10 -N1 -n1 -c 48 bash -s" <<'REMOTO'
ml GCC >/dev/null 2>&1
W=$(mktemp -d "$PWD/barreiras_tmp.XXXX") || exit 1
cp -r src Makefile inputdata.txt "$W"/ && cd "$W" || exit 1

cat > instr.py <<'PY'
import sys, os
src = sys.argv[1]
def rd(f): return open(os.path.join(src, f)).read()
def wr(f, s): open(os.path.join(src, f), 'w').write(s)

def wrap(s, pragma, k):
    """Troca '#pragma omp parallel for X' + ciclo por parallel{ for nowait } com temporizadores."""
    if s.count(pragma) != 1:
        sys.exit("instr: pragma nao encontrado 1x: " + pragma)
    a = s.index(pragma)
    clauses = pragma.strip()[len("#pragma omp parallel for"):]
    red = clauses[clauses.index("reduction"):] if "reduction" in clauses else ""
    b = s.index("{", a)
    depth, e = 0, b
    while True:
        if s[e] == "{": depth += 1
        elif s[e] == "}":
            depth -= 1
            if depth == 0: break
        e += 1
    head = s[a + len(pragma.rstrip("\n")):b]
    body = s[b:e + 1]
    new = ("{ double t0_ = omp_get_wtime();\n"
           "#pragma omp parallel " + red + "\n"
           "{ double ts_ = omp_get_wtime();\n"
           "#pragma omp for schedule(static) nowait" + head + body + "\n"
           "  double te_ = omp_get_wtime(); int id_ = omp_get_thread_num();\n"
           f"  BAR_S[{k}][id_] += ts_ - t0_; BAR_W[{k}][id_] += te_ - ts_;\n"
           "}\n"
           f"BAR_R[{k}] += omp_get_wtime() - t0_; }}\n")
    return s[:a] + new + s[e + 1:]

h = rd("md.h")
h = h.replace("#endif", "#include <omp.h>\n#define BAR_MAXT 256\n"
              "extern double BAR_S[3][BAR_MAXT], BAR_W[3][BAR_MAXT], BAR_R[3];\n#endif")
wr("md.h", h)

f = rd("forces.c")
f = wrap(f, "#pragma omp parallel for schedule(static) reduction(+ : pot)", 1)
wr("forces.c", f)

m = rd("MD.cpp")
m = wrap(m, "#pragma omp parallel for schedule(static)\n", 0)
m = wrap(m, "#pragma omp parallel for schedule(static) reduction(+ : psum, v2sum)", 2)
def sub(old, new):
    global m
    if m.count(old) != 1: sys.exit("instr: nao encontrado 1x: " + old[:50])
    m = m.replace(old, new)
sub('#include "md.h"\n', '#include "md.h"\n'
    'double BAR_S[3][BAR_MAXT], BAR_W[3][BAR_MAXT], BAR_R[3];\nstatic double BAR_LOOP;\n')
sub('    for (i = 0; i < NumTime + 1; i++)\n',
    '    memset(BAR_S, 0, sizeof BAR_S); memset(BAR_W, 0, sizeof BAR_W); memset(BAR_R, 0, sizeof BAR_R);\n'
    '    double tl0_ = omp_get_wtime();\n'
    '    for (i = 0; i < NumTime + 1; i++)\n')
sub('    Pavg /= NumTime;\n', '    BAR_LOOP = omp_get_wtime() - tl0_;\n    Pavg /= NumTime;\n')
sub('    fclose(tfp);\n    fclose(ofp);\n    fclose(afp);\n    return EXIT_SUCCESS;',
    '    { int nt = omp_get_max_threads();\n'
    '      fprintf(stderr, "BAR LOOP %.6f %d\\n", BAR_LOOP, nt);\n'
    '      for (int k = 0; k < 3; k++) for (int t = 0; t < nt; t++)\n'
    '        fprintf(stderr, "BAR %d %d %.6f %.6f %.6f\\n", k, t, BAR_R[k], BAR_S[k][t], BAR_W[k][t]); }\n'
    '    fclose(tfp);\n    fclose(ofp);\n    fclose(afp);\n    return EXIT_SUCCESS;')
wr("MD.cpp", m)
PY
cat > analisa.py <<'PY'
import sys
loop, nt = None, 0
R, Sx, W = {}, {}, {}
for line in open(sys.argv[1]):
    t = line.split()
    if not t or t[0] != "BAR": continue
    if t[1] == "LOOP":
        loop, nt = float(t[2]), int(t[3]); continue
    k, th = int(t[1]), int(t[2])
    R[k] = float(t[3]); Sx.setdefault(k, []).append(float(t[4])); W.setdefault(k, []).append(float(t[5]))
nomes = ["VelocityVerlet ciclo 1", "computeAccelerations", "VelocityVerlet ciclo 2"]
print(f"\n################ {nt} threads | ciclo principal = {loop:.4f} s (201 passos)\n")
print("Tempos médios por thread, somados nos 201 passos (s). Em cada região: região = arranque + trabalho + espera.\n")
print(f"| região | região (s) | arranque (fork) | trabalho médio | trabalho mín | trabalho máx | espera na barreira | % do ciclo (espera) |")
print(f"|---|---|---|---|---|---|---|---|")
tot_wait = tot_fork = 0
for k in range(3):
    s = sum(Sx[k]) / nt; w = sum(W[k]) / nt; wait = R[k] - s - w
    tot_wait += wait; tot_fork += s
    print(f"| {nomes[k]} | {R[k]:.4f} | {s:.4f} | {w:.4f} | {min(W[k]):.4f} | {max(W[k]):.4f} | {wait:.4f} | {100*wait/loop:.1f}% |")
serie = loop - sum(R.values())
print(f"\n| fora das regiões (só a master: série, printf, fprintf) | {serie:.4f} s | {100*serie/loop:.1f}% do ciclo |")
print(f"| arranque das regiões (fork, todas) | {tot_fork:.4f} s | {100*tot_fork/loop:.1f}% |")
print(f"| espera nas barreiras de fim de região (todas) | {tot_wait:.4f} s | {100*tot_wait/loop:.1f}% |")
print("\nespera na barreira  ~ gomp_team_barrier_wait_end no perf (desequilíbrio + redução no fim)")
print("fora das regiões + arranque ~ gomp_barrier_wait_end no perf (workers parados na doca)")
if 1 in W:
    w = W[1]
    print(f"\ncomputeAccelerations, trabalho por thread: mín {min(w):.4f} (t{w.index(min(w))}), máx {max(w):.4f} (t{w.index(max(w))}), desequilíbrio (máx/média - 1) = {100*(max(w)/(sum(w)/nt)-1):.1f}%")
    ordem = sorted(range(nt), key=lambda t: -w[t])[:5]
    print("5 threads mais lentas: " + ", ".join(f"t{t} {w[t]:.4f}" for t in ordem))
PY
python3 instr.py src || exit 1
make -s md >/dev/null || { echo "ERRO de compilação"; exit 1; }

for T in $THREADS; do
  OMP_NUM_THREADS=$T OMP_PROC_BIND=close OMP_PLACES=cores ./md < inputdata.txt 2> bar_$T.txt > /dev/null
  python3 analisa.py bar_$T.txt
done
cd .. && rm -rf "$W"
REMOTO
