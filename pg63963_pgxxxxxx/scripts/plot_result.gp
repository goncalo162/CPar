# Uso (a partir da raiz do projeto):
#   gnuplot -e "csvfile='benchmark_2178367/results.csv'; outdir='plots'" scripts/plot_result.gp
# Gera PNGs em plots/ e um único PDF (charts.pdf).
# Requer gnuplot >= 5.2 e awk/sort.

if (!exists("csvfile")) csvfile = "results.csv"
if (!exists("outdir"))  outdir  = "plots"
system("mkdir -p " . outdir)

if (system("test -f '" . csvfile . "' && echo 1 || echo 0") eq "0") {
    print "ERRO: não encontrei o ficheiro '" . csvfile . "' (cwd: " . system("pwd") . ")"
    exit gnuplot
}

set datafile separator ","
set grid
set border linewidth 1.2
set pointsize 1.2
set lmargin 14
set rmargin 4
set tmargin 3
set bmargin 6
set xlabel "Número de threads"
set key outside bottom center horizontal

# ------------------------------------------------------------
# Eixo X dinâmico: threads presentes no CSV
# ------------------------------------------------------------
threads = system("awk -F, 'NR>1 {print $1}' " . csvfile . " | sort -un | paste -sd, -")
tmin = real(system("awk -F, 'NR>1 {print $1}' " . csvfile . " | sort -n | head -1"))
tmax = real(system("awk -F, 'NR>1 {print $1}' " . csvfile . " | sort -n | tail -1"))

set logscale x 2
set xrange [tmin/1.25 : tmax*1.25]
set format x "%g"
eval "set xtics (" . threads . ")"

# ------------------------------------------------------------
# Helpers: filtram o CSV com awk (garante linhas contínuas)
# ------------------------------------------------------------
filt(k,m) = sprintf("awk -F, -v OFS=, -v k='%s' -v m='%s' 'NR>1 && $2==k && $3==m {print $1,$4}' %s | sort -t, -k1,1n", k, m, csvfile)
src(k,m)  = "< " . filt(k,m)
cnt(k,m)  = real(system(filt(k,m) . " | wc -l"))

# mínimo e máximo calculados diretamente do CSV (independentes de ranges ativos)
amin(k,m) = real(system(sprintf("awk -F, -v k='%s' -v m='%s' 'NR>1 && $2==k && $3==m {v=$4+0; if(n++==0||v<mn)mn=v} END{printf \"%%.12g\", mn}' %s", k, m, csvfile)))
amax(k,m) = real(system(sprintf("awk -F, -v k='%s' -v m='%s' 'NR>1 && $2==k && $3==m {v=$4+0; if(n++==0||v>mx)mx=v} END{printf \"%%.12g\", mx}' %s", k, m, csvfile)))

# ------------------------------------------------------------
# Speedup: T(menor nº de threads) / T(n), calculado a partir do tempo
# ------------------------------------------------------------
has_elapsed = cnt("perf", "seconds elapsed")

spd_awk = 'NR>1 && $2=="perf" && $3=="seconds elapsed" {t[$1]=$4+0; if(mn==""||$1+0<mn) mn=$1+0} END{for(n in t) printf "%s,%.6f\n", n, t[mn]/t[n]}'
spd_cmd = "awk -F, '" . spd_awk . "' " . csvfile . " | sort -t, -k1,1n"
spd_src = "< " . spd_cmd

id_awk  = 'NR>1 && $2=="perf" && $3=="seconds elapsed" {t[$1]=1; if(mn==""||$1+0<mn) mn=$1+0} END{for(n in t) printf "%s,%.6f\n", n, n/mn}'
ideal_src = "< awk -F, '" . id_awk . "' " . csvfile . " | sort -t, -k1,1n"

# ------------------------------------------------------------
# Definição dos gráficos (metric2 vazio => série única)
# ------------------------------------------------------------
NCH = 6
array ch_title[NCH]
array ch_ylabel[NCH]
array ch_file[NCH]
array ch_kind1[NCH]
array ch_metric1[NCH]
array ch_kind2[NCH]
array ch_metric2[NCH]

ch_title[1]="Instruções";              ch_ylabel[1]="Instruções"
ch_file[1]="instructions";             ch_kind1[1]="perf"; ch_metric1[1]="instructions"
ch_kind2[1]=""; ch_metric2[1]=""

ch_title[2]="Ciclos";                  ch_ylabel[2]="Ciclos"
ch_file[2]="cycles";                   ch_kind1[2]="perf"; ch_metric1[2]="cycles"
ch_kind2[2]=""; ch_metric2[2]=""

ch_title[3]="L1: loads vs misses";     ch_ylabel[3]="Acessos"
ch_file[3]="l1_loads_vs_misses";       ch_kind1[3]="perf"; ch_metric1[3]="L1-dcache-loads"
ch_kind2[3]="perf"; ch_metric2[3]="L1-dcache-load-misses"

ch_title[4]="Branches: pred vs miss";  ch_ylabel[4]="Branches"
ch_file[4]="branch_pred_vs_miss";      ch_kind1[4]="perf"; ch_metric1[4]="br_pred"
ch_kind2[4]="perf"; ch_metric2[4]="br_mis_pred"

ch_title[5]="FLOPs";                   ch_ylabel[5]="FLOPs"
ch_file[5]="flops";                    ch_kind1[5]="derived"; ch_metric1[5]="FLOPs"
ch_kind2[5]=""; ch_metric2[5]=""

ch_title[6]="Tempo de execução";       ch_ylabel[6]="Segundos"
ch_file[6]="elapsed";                  ch_kind1[6]="perf"; ch_metric1[6]="seconds elapsed"
ch_kind2[6]=""; ch_metric2[6]=""

# ------------------------------------------------------------
# Passada 1: PNGs | Passada 2: PDF multi-página
# ------------------------------------------------------------
do for [pass=1:2] {
    if (pass == 1) {
        set terminal pngcairo size 1200,750 enhanced font "Arial,12"
    } else {
        set terminal pdfcairo size 12in,7.5in enhanced color solid font ",12"
        set output outdir . "/charts.pdf"
    }

    do for [i=1:NCH] {
        f1 = src(ch_kind1[i], ch_metric1[i])
        has1 = cnt(ch_kind1[i], ch_metric1[i])
        if (has1 == 0) {
            print "AVISO: sem dados para '" . ch_title[i] . "' - gráfico ignorado"
            continue
        }
        has2 = 0
        if (ch_metric2[i] ne "") {
            f2 = src(ch_kind2[i], ch_metric2[i])
            has2 = cnt(ch_kind2[i], ch_metric2[i])
        }

        # ---- escala Y adaptada aos dados (via awk, sem stats) ----
        unset logscale y
        ymin = amin(ch_kind1[i], ch_metric1[i])
        ymax = amax(ch_kind1[i], ch_metric1[i])
        if (has2 > 0) {
            ymin2 = amin(ch_kind2[i], ch_metric2[i])
            ymax2 = amax(ch_kind2[i], ch_metric2[i])
            ymin = (ymin2 < ymin) ? ymin2 : ymin
            ymax = (ymax2 > ymax) ? ymax2 : ymax
        }
        ratio = (ymin > 0) ? ymax/ymin : 1e9

        if (ratio >= 20) {
            set logscale y 10
            set yrange [ymin/2 : ymax*3]
            set format y "10^{%L}"
        } else if (ratio >= 2) {
            set yrange [0 : ymax*1.2]
            set format y "%.3g"
        } else {
            d = ymax - ymin
            pad = (d > 0) ? 0.3*d : ((ymax != 0) ? 0.05*abs(ymax) : 1)
            set yrange [ymin - pad : ymax + pad]
            set format y "%.4g"
        }

        if (pass == 1) { set output outdir . "/" . ch_file[i] . ".png" }
        set title ch_title[i]
        set ylabel ch_ylabel[i]

        if (has2 > 0) {
            plot f1 using 1:2 with linespoints lw 2 pt 7 title ch_metric1[i], \
                 f1 using 1:2:1 with labels offset 0,1 font ",10" notitle, \
                 f2 using 1:2 with linespoints lw 2 pt 5 title ch_metric2[i], \
                 f2 using 1:2:1 with labels offset 0,-1 font ",10" notitle
        } else {
            plot f1 using 1:2 with linespoints lw 2 pt 7 title ch_metric1[i], \
                 f1 using 1:2:1 with labels offset 0,1 font ",10" notitle
        }
    }
    # --------------------------------------------------------
    # Ganho (speedup) = T(ref) / T(n), com ref = menor nº de threads
    # --------------------------------------------------------
    if (has_elapsed > 0) {
        if (pass == 1) { set output outdir . "/speedup.png" }
        unset logscale y
        ymax_sp = real(system(spd_cmd . " | awk -F, '{if(NR==1||$2>m)m=$2} END{print m}'"))
        ymax_id = tmax / tmin
        ytop = ((ymax_sp > ymax_id) ? ymax_sp : ymax_id) * 1.15
        set yrange [0 : ytop]
        set format y "%.3g"
        set title sprintf("Ganho (speedup) relativo a %d threads", tmin)
        set ylabel sprintf("Speedup = T_{%d} / T_n", tmin)

        plot ideal_src using 1:2 with lines dt 2 lw 2 lc rgb "gray40" title "Ideal (linear)", \
             spd_src using 1:2 with linespoints lw 2 pt 7 title "Medido", \
             spd_src using 1:2:1 with labels offset 0,1 font ",10" notitle
    }
    unset output
}

print "PNGs gerados em: " . outdir
print "PDF único: " . outdir . "/charts.pdf"
