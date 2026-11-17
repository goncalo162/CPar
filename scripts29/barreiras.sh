#!/bin/bash
# De onde vem o tempo das barreiras? Mede, em cada região paralela e para cada thread:
#   arranque (fork) + trabalho + espera na barreira do fim = tempo da região
# e o tempo fora das regiões (só a master trabalha, os workers estão parados).
#
# No computeAccelerations (forces.c ou newton.c, o que o Makefile compilar) mede cada
# "omp for" à parte (forças e redução da 3.ª lei de Newton) e a espera de cada barreira.
#
# Não mexe no teu código: no cluster copia src/, Makefile e inputdata.txt para uma pasta
# temporária, mete omp_get_wtime à volta de cada ciclo ("omp for" passa a nowait + barreira
# explícita, que é o mesmo), compila com o teu Makefile, corre e apaga a pasta.
#
# Uso (no Mac, na pasta CParTP):
#   ./barreiras.sh          # 48 threads
#   ./barreiras.sh 24 48    # outros nº de threads
#   ./barreiras.sh --old    # igual, mas com o VelocityVerlet antigo (reduction) só na cópia temporária
# (não escrevas comentários '# ...' na mesma linha no zsh: viram argumentos)
#
# Usa o src/ e o Makefile que estão NO CLUSTER (envia antes com upload_files.sh).

VV_OLD=0
if [ "$1" = "--old" ]; then VV_OLD=1; shift; fi
THREADS="${*:-48}"
REMOTE=deucalion
DIR=/projects/F202500010HPCVLABUMINHO/2026-2027cp/mei.2026.pg63522
ACCOUNT=f202500010hpcvlabuminhoa

ssh "$REMOTE" "cd $DIR && THREADS='$THREADS' VV_OLD='$VV_OLD' srun -A $ACCOUNT -p normal-arm -t 10 -N1 -n1 -c 48 bash -s" <<'REMOTO'
ml GCC >/dev/null 2>&1
W=$(mktemp -d "$PWD/barreiras_tmp.XXXX") || exit 1
cp -r src Makefile inputdata.txt "$W"/ && cd "$W" || exit 1

# --- com --old: troca, só nesta cópia temporária, o VelocityVerlet pelo antigo (com reduction) ---
if [ "$VV_OLD" = 1 ]; then
cat > vv_old.txt <<'VVOLD'
double VelocityVerlet(double dt, int iter, FILE *fp)
{
    (void)iter;
    (void)fp;

    double psum = 0.0, v2sum = 0.0;
    const double half_dt = 0.5 * dt;
    const double half_dt2 = 0.5 * dt * dt;

/* Primeira metade do passo: posições + primeira metade das velocidades. */
#pragma omp parallel for schedule(static)
    for (int i = 0; i < N; i++)
    {
        rx[i] += vx[i] * dt + ax[i] * half_dt2;
        ry[i] += vy[i] * dt + ay[i] * half_dt2;
        rz[i] += vz[i] * dt + az[i] * half_dt2;

        vx[i] += ax[i] * half_dt;
        vy[i] += ay[i] * half_dt;
        vz[i] += az[i] * half_dt;
    }

    computeAccelerations();

/* Segunda metade do passo + pressão nas paredes. */
#pragma omp parallel for schedule(static) reduction(+ : psum, v2sum)
    for (int i = 0; i < N; i++)
    {
        vx[i] += ax[i] * half_dt;
        vy[i] += ay[i] * half_dt;
        vz[i] += az[i] * half_dt;

        if (rx[i] < 0.0)
        {
            vx[i] = -vx[i];
            psum += 2.0 * m * fabs(vx[i]) / dt;
        }
        else if (rx[i] >= L)
        {
            vx[i] = -vx[i];
            psum += 2.0 * m * fabs(vx[i]) / dt;
        }

        if (ry[i] < 0.0)
        {
            vy[i] = -vy[i];
            psum += 2.0 * m * fabs(vy[i]) / dt;
        }
        else if (ry[i] >= L)
        {
            vy[i] = -vy[i];
            psum += 2.0 * m * fabs(vy[i]) / dt;
        }

        if (rz[i] < 0.0)
        {
            vz[i] = -vz[i];
            psum += 2.0 * m * fabs(vz[i]) / dt;
        }
        else if (rz[i] >= L)
        {
            vz[i] = -vz[i];
            psum += 2.0 * m * fabs(vz[i]) / dt;
        }

        /* depois dos ressaltos (o sinal de v não muda v^2) */
        v2sum += vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i];
    }

    V2_atual = v2sum;
    return psum / (6.0 * L * L);
}
VVOLD
python3 - <<'TROCA' || exit 1
import re, sys
m = open("src/MD.cpp").read().replace("\r\n", "\n")
ms = list(re.finditer(r"^[ \t]*double[ \t]+VelocityVerlet[ \t]*\([^)]*\)[ \t]*\{?", m, re.M))
ms = [x for x in ms if not m[x.end():].lstrip().startswith(";")]
if len(ms) != 1:
    sys.exit("troca: esperava 1 definição do VelocityVerlet, vi %d: %r" % (len(ms), [x.group(0) for x in ms]))
a = ms[0].start()
b = m.index("{", a)
depth, e = 0, b
while True:
    if m[e] == "{": depth += 1
    elif m[e] == "}":
        depth -= 1
        if depth == 0: break
    e += 1
m = m[:a] + open("vv_old.txt").read() + m[e + 1:].lstrip("\n")
open("src/MD.cpp", "w").write(m)
print("== VelocityVerlet antigo (reduction) aplicado na cópia temporária", file=sys.stderr)
TROCA
fi

cat > instr.py <<'PY'
import sys, os, re
src = sys.argv[1]
def rd(f): return open(os.path.join(src, f)).read()
def wr(f, s): open(os.path.join(src, f), 'w').write(s)

def fecha(s, b):
    """índice do '}' que fecha o '{' em b"""
    depth, e = 0, b
    while True:
        if s[e] == "{": depth += 1
        elif s[e] == "}":
            depth -= 1
            if depth == 0: return e
        e += 1

def find1(s, rx, what):
    ms = list(re.finditer(rx, s, re.M))
    if len(ms) != 1: sys.exit("instr: não reconheci %s (%d candidatos)" % (what, len(ms)))
    return ms[0].start()

PAR = r"^[ \t]*#[ \t]*pragma[ \t]+omp[ \t]+parallel(?![ \t]+for)\b"

def wrap(s, pragma, k):
    """VV: '#pragma omp parallel for X' + ciclo -> parallel{ for nowait } com temporizadores."""
    if s.count(pragma) != 1: sys.exit("instr: pragma nao encontrado 1x: " + pragma)
    a = s.index(pragma)
    clauses = pragma.strip()[len("#pragma omp parallel for"):]
    red = clauses[clauses.index("reduction"):] if "reduction" in clauses else ""
    b = s.index("{", a); e = fecha(s, b)
    head = s[a + len(pragma.rstrip("\n")):b]
    new = ("{ double t0_ = omp_get_wtime();\n#pragma omp parallel " + red + "\n"
           "{ double ts_ = omp_get_wtime();\n#pragma omp for schedule(static) nowait" + head + s[b:e + 1] + "\n"
           "  double te_ = omp_get_wtime(); int id_ = omp_get_thread_num();\n"
           f"  BAR_S[{k}][id_] += ts_ - t0_; BAR_W[{k}][id_] += te_ - ts_;\n}}\n"
           f"BAR_R[{k}] += omp_get_wtime() - t0_; }}\n")
    return s[:a] + new + s[e + 1:]

def wrap_block(s, a, k):
    """VV: região 'parallel { ...; omp for ... }' com 1 omp for."""
    le = s.index("\n", a)
    prag = s[a:le].split("//")[0].strip()
    b = s.index("{", le); e = fecha(s, b)
    body, n = re.subn(r"#[ \t]*pragma[ \t]+omp[ \t]+for[ \t]+schedule\([ \t]*static[ \t]*\)[^\n]*\n",
                      "#pragma omp for schedule(static) nowait\n", s[b + 1:e])
    if n != 1: sys.exit("instr: esperava 1 'omp for' dentro do bloco, vi %d" % n)
    new = ("{ double t0_ = omp_get_wtime();\n" + prag + "\n{ double ts_ = omp_get_wtime();\n" + body +
           "\n  double te_ = omp_get_wtime(); int id_ = omp_get_thread_num();\n"
           f"  BAR_S[{k}][id_] += ts_ - t0_; BAR_W[{k}][id_] += te_ - ts_;\n}}\n"
           f"BAR_R[{k}] += omp_get_wtime() - t0_; }}\n")
    return s[:a] + new + s[e + 1:]

def wrap_forces(s):
    """forces: região 'parallel { ... }' com 1 ou mais 'omp for'. Para cada omp for j mede, por
    thread, o trabalho (desde o fim do anterior) e a espera na barreira dele (explícita aqui, com
    nowait no for: é o mesmo que a implícita)."""
    a = find1(s, PAR, "a região paralela do computeAccelerations")
    le = s.index("\n", a)
    prag = s[a:le].split("//")[0].strip()
    b = s.index("{", le); e = fecha(s, b)
    body = s[b + 1:e]
    fors = list(re.finditer(r"^[ \t]*#[ \t]*pragma[ \t]+omp[ \t]+for\b([^\n]*)\n", body, re.M))
    if not fors or len(fors) > 3: sys.exit("instr: esperava 1 a 3 'omp for' no forces, vi %d" % len(fors))
    for j in reversed(range(len(fors))):
        f = fors[j]
        cl = f.group(1).split("//")[0]
        nowait = "nowait" in cl
        lb = body.index("{", f.end()); le2 = fecha(body, lb)
        depois = (f"\n{{ double tq_ = omp_get_wtime(); FOR_W[{j}][id_] += tq_ - tl_; tl_ = tq_; }}\n")
        if not nowait:
            depois += ("#pragma omp barrier\n"
                       f"{{ double tq_ = omp_get_wtime(); FOR_B[{j}][id_] += tq_ - tl_; tl_ = tq_; }}\n")
        body = body[:le2 + 1] + depois + body[le2 + 1:]
        pr = "#pragma omp for" + cl.rstrip() + ("" if nowait else " nowait") + "\n"
        body = body[:f.start()] + pr + body[f.end():]
    new = ("{ double t0_ = omp_get_wtime();\n" + prag + "\n{ double tl_ = omp_get_wtime(); int id_ = omp_get_thread_num();\n"
           "  FOR_S[id_] += tl_ - t0_;\n" + body +
           "\n  FOR_W[3][id_] += omp_get_wtime() - tl_;\n}\n"
           f"FOR_R += omp_get_wtime() - t0_; FOR_NF = {len(fors)}; }}\n")
    return s[:a] + new + s[e + 1:]

h = rd("md.h")
h = h.replace("#endif", "#include <omp.h>\n#define BAR_MAXT 256\n"
              "extern double BAR_S[3][BAR_MAXT], BAR_W[3][BAR_MAXT], BAR_R[3];\n"
              "extern double FOR_S[BAR_MAXT], FOR_W[4][BAR_MAXT], FOR_B[4][BAR_MAXT], FOR_R; extern int FOR_NF;\n#endif")
wr("md.h", h)

# ficheiro com o computeAccelerations que o Makefile compila (forces.c, newton.c, ...)
mk = open(os.path.join(src, "..", "Makefile")).read()
cands = []
for fn in sorted(os.listdir(src)):
    if fn.endswith(".c") and re.search(r"void[ \t]+computeAccelerations[ \t]*\([ \t]*void[ \t]*\)[ \t\n]*\{", rd(fn)):
        cands.append(fn)
usados = [fn for fn in cands if re.search(r"\b" + re.escape(fn[:-2]) + r"\.(c|o)\b", mk)]
if len(usados) != 1: sys.exit("instr: não sei que ficheiro tem o computeAccelerations (candidatos %s, no Makefile %s)" % (cands, usados))
FF = usados[0]
print("== forças em src/" + FF, file=sys.stderr)
wr(FF, wrap_forces(rd(FF)))

m = rd("MD.cpp")
P2 = "#pragma omp parallel for schedule(static) reduction(+ : psum, v2sum)"
if P2 in m: m = wrap(m, P2, 2)
else: m = wrap_block(m, find1(m, PAR, "o 2.º ciclo do VelocityVerlet"), 2)
m = wrap(m, "#pragma omp parallel for schedule(static)\n", 0)
def sub(old, new):
    global m
    if m.count(old) != 1: sys.exit("instr: nao encontrado 1x: " + old[:50])
    m = m.replace(old, new)
sub('#include "md.h"\n', '#include "md.h"\n'
    'double BAR_S[3][BAR_MAXT], BAR_W[3][BAR_MAXT], BAR_R[3];\n'
    'double FOR_S[BAR_MAXT], FOR_W[4][BAR_MAXT], FOR_B[4][BAR_MAXT], FOR_R; int FOR_NF;\nstatic double BAR_LOOP;\n')
sub('    for (i = 0; i < NumTime + 1; i++)\n',
    '    memset(BAR_S, 0, sizeof BAR_S); memset(BAR_W, 0, sizeof BAR_W); memset(BAR_R, 0, sizeof BAR_R);\n'
    '    memset(FOR_S, 0, sizeof FOR_S); memset(FOR_W, 0, sizeof FOR_W); memset(FOR_B, 0, sizeof FOR_B); FOR_R = 0;\n'
    '    double tl0_ = omp_get_wtime();\n'
    '    for (i = 0; i < NumTime + 1; i++)\n')
sub('    Pavg /= NumTime;\n', '    BAR_LOOP = omp_get_wtime() - tl0_;\n    Pavg /= NumTime;\n')
sub('    fclose(tfp);\n    fclose(ofp);\n    fclose(afp);\n    return EXIT_SUCCESS;',
    '    { int nt = omp_get_max_threads();\n'
    '      fprintf(stderr, "BAR LOOP %.6f %d %d %.6f\\n", BAR_LOOP, nt, FOR_NF, FOR_R);\n'
    '      for (int k = 0; k < 3; k += 2) for (int t = 0; t < nt; t++)\n'
    '        fprintf(stderr, "BAR %d %d %.6f %.6f %.6f\\n", k, t, BAR_R[k], BAR_S[k][t], BAR_W[k][t]);\n'
    '      for (int t = 0; t < nt; t++) {\n'
    '        fprintf(stderr, "FOR %d %.6f", t, FOR_S[t]);\n'
    '        for (int j = 0; j < 4; j++) fprintf(stderr, " %.6f %.6f", FOR_W[j][t], FOR_B[j][t]);\n'
    '        fprintf(stderr, "\\n"); } }\n'
    '    fclose(tfp);\n    fclose(ofp);\n    fclose(afp);\n    return EXIT_SUCCESS;')
wr("MD.cpp", m)
PY
cat > analisa.py <<'PY'
import sys
loop = nt = nf = None
R, Sx, W = {}, {}, {}
FS, FW, FB = [], [], []
for line in open(sys.argv[1]):
    t = line.split()
    if not t: continue
    if t[0] == "BAR" and t[1] == "LOOP":
        loop, nt, nf, FR = float(t[2]), int(t[3]), int(t[4]), float(t[5])
    elif t[0] == "BAR":
        k = int(t[1]); R[k] = float(t[3])
        Sx.setdefault(k, []).append(float(t[4])); W.setdefault(k, []).append(float(t[5]))
    elif t[0] == "FOR":
        v = list(map(float, t[2:]))
        FS.append(v[0]); FW.append(v[1::2]); FB.append(v[2::2])
med = lambda x: sum(x) / len(x)
print(f"\n################ {nt} threads | ciclo principal = {loop:.4f} s (201 passos)\n")
print("Tempos por thread somados nos 201 passos (s).\n")

print("## VelocityVerlet (região = arranque + trabalho + espera)\n")
print("| região | região | arranque | trabalho médio | mín | máx | espera |")
print("|---|---|---|---|---|---|---|")
nomes = {0: "VV ciclo 1", 2: "VV ciclo 2"}
tot_fork = tot_wait = 0
for k in (0, 2):
    s = med(Sx[k]); w = med(W[k]); wait = R[k] - s - w
    tot_fork += s; tot_wait += wait
    print(f"| {nomes[k]} | {R[k]:.4f} | {s:.4f} | {w:.4f} | {min(W[k]):.4f} | {max(W[k]):.4f} | {wait:.4f} |")

print(f"\n## computeAccelerations: região {FR:.4f} s ({100*FR/loop:.1f}% do ciclo), {nf} 'omp for'\n")
print("| parte | trabalho médio | mín | máx | desequilíbrio (máx/média-1) | espera na barreira (média) | % do ciclo (espera) |")
print("|---|---|---|---|---|---|---|")
fs = med(FS); tot_fork += fs
print(f"| arranque (fork) | {fs:.4f} | {min(FS):.4f} | {max(FS):.4f} | | | |")
for j in range(nf):
    w = [FW[t][j] for t in range(nt)]; b = [FB[t][j] for t in range(nt)]
    nome = "ciclo 1 (forças)" if j == 0 else ("ciclo %d (redução)" % (j + 1) if j == nf - 1 else "ciclo %d" % (j + 1))
    tot_wait += med(b)
    print(f"| {nome} | {med(w):.4f} | {min(w):.4f} | {max(w):.4f} | {100*(max(w)/med(w)-1):.1f}% | {med(b):.4f} | {100*med(b)/loop:.1f}% |")
fim = [FW[t][3] for t in range(nt)]
fim_wait = FR - fs - med([sum(FW[t][j] + FB[t][j] for j in range(nf)) for t in range(nt)]) - med(fim)
tot_wait += max(fim_wait, 0)
print(f"| resto + barreira do fim | {med(fim):.4f} | | | | {fim_wait:.4f} | {100*fim_wait/loop:.1f}% |")

serie = loop - R[0] - R[2] - FR
print(f"\n| fora das regiões (só a master) | {serie:.4f} s | {100*serie/loop:.1f}% do ciclo |")
print(f"| arranque das regiões (fork, todas) | {tot_fork:.4f} s | {100*tot_fork/loop:.1f}% |")
print(f"| espera em barreiras (todas) | {tot_wait:.4f} s | {100*tot_wait/loop:.1f}% |")

w = [FW[t][0] for t in range(nt)]; b = [FB[t][0] for t in range(nt)]
ordem = sorted(range(nt), key=lambda t: -w[t])[:5]
print("\nforças, 5 threads mais lentas: " + ", ".join(f"t{t} {w[t]:.4f}" for t in ordem))
ordem = sorted(range(nt), key=lambda t: w[t])[:5]
print("forças, 5 threads mais rápidas: " + ", ".join(f"t{t} {w[t]:.4f}" for t in ordem))
print("forças por grupo de 12 threads (1 CMG com close/cores):")
for g in range(0, nt, 12):
    gw, gb = w[g:g + 12], b[g:g + 12]
    print(f"  threads {g:3d}-{g + len(gw) - 1:3d}: trabalho médio {med(gw):.4f} s   espera média {med(gb):.4f} s")
PY
python3 instr.py src || exit 1
make -s md >/dev/null || { echo "ERRO de compilação"; exit 1; }

for T in $THREADS; do
  OMP_NUM_THREADS=$T OMP_PROC_BIND=close OMP_PLACES=cores ./md < inputdata.txt 2> bar_$T.txt > /dev/null
  python3 analisa.py bar_$T.txt
done
cd .. && rm -rf "$W"
REMOTO
