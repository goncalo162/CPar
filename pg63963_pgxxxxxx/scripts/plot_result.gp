# Uso:
#   gnuplot -e "csvfile='results.csv'" plot_results.gp
# Gera todos os PNGs em plots/ e um único PDF com todos os gráficos.

if (!exists("csvfile"))  csvfile  = "results.csv"
if (!exists("outdir"))   outdir   = "plots"

set datafile separator ","
set datafile columnheaders
set grid
set border linewidth 1.2
set pointsize 1.2
set lmargin 12
set rmargin 4
set tmargin 3
set bmargin 4
set xlabel "Número de threads"
set xtics (1, 2, 4, 8, 16, 32, 48)
set format x "%g"
set logscale x 2
set key top left

# ------------------------------------------------------------
# Definição dos gráficos (m2 vazio => série única)
# ------------------------------------------------------------
NCH = 6
array ch_title[NCH]
array ch_ylabel[NCH]
array ch_file[NCH]
array ch_kind1[NCH]
array ch_metric1[NCH]
array ch_kind2[NCH]
array ch_metric2[NCH]
array ch_logy[NCH]

ch_title[1]="Instruções";             ch_ylabel[1]="Instruções"
ch_file[1]="instructions";           ch_kind1[1]="perf"; ch_metric1[1]="instructions"
ch_kind2[1]=""; ch_metric2[1]="";    ch_logy[1]=1

ch_title[2]="Ciclos";                ch_ylabel[2]="Ciclos"
ch_file[2]="cycles";                ch_kind1[2]="perf"; ch_metric1[2]="cycles"
ch_kind2[2]=""; ch_metric2[2]="";    ch_logy[2]=1

ch_title[3]="L1: loads vs misses";   ch_ylabel[3]="Acessos"
ch_file[3]="l1_loads_vs_misses";     ch_kind1[3]="perf"; ch_metric1[3]="L1-dcache-loads"
ch_kind2[3]="perf"; ch_metric2[3]="L1-dcache-load-misses"; ch_logy[3]=1

ch_title[4]="Branches: pred vs miss"; ch_ylabel[4]="Branches"
ch_file[4]="branch_pred_vs_miss";    ch_kind1[4]="perf"; ch_metric1[4]="br_pred"
ch_kind2[4]="perf"; ch_metric2[4]="br_mis_pred"; ch_logy[4]=1

ch_title[5]="FLOPs";                 ch_ylabel[5]="FLOPs"
ch_file[5]="flops";                  ch_kind1[5]="derived"; ch_metric1[5]="FLOPs"
ch_kind2[5]=""; ch_metric2[5]="";    ch_logy[5]=1

ch_title[6]="Tempo de execução";     ch_ylabel[6]="Segundos"
ch_file[6]="elapsed";                ch_kind1[6]="perf"; ch_metric1[6]="seconds elapsed"
ch_kind2[6]=""; ch_metric2[6]="";    ch_logy[6]=0

# ------------------------------------------------------------
# Passada 1: PNGs individuais
# Passada 2: um único PDF multi-página (charts.pdf)
# ------------------------------------------------------------
do for [f=1:2] {
    if (f == 1) {
        set terminal pngcairo size 1200,750 enhanced font "Arial,12"
    } else {
        set terminal pdfcairo size 12in,7.5in enhanced color solid font ",12"
        set output outdir . "/charts.pdf"
    }

    do for [i=1:NCH] {
        if (f == 1) { set output outdir . "/" . ch_file[i] . ".png" }
        set title ch_title[i]
        set ylabel ch_ylabel[i]
        if (ch_logy[i]) { set logscale y } else { unset logscale y }

        plot \
            csvfile using \
                (strcol(2) eq ch_kind1[i] && strcol(3) eq ch_metric1[i] ? \
                 real(column(1)) : 1/0):4 \
                with linespoints linewidth 2 pointtype 7 title ch_metric1[i], \
            csvfile using \
                (strcol(2) eq ch_kind2[i] && strcol(3) eq ch_metric2[i] ? \
                 real(column(1)) : 1/0):4 \
                with linespoints linewidth 2 pointtype 5 title ch_metric2[i]
    }
}

unset output
print "PNGs gerados em: " . outdir
print "PDF único: " . outdir . "/charts.pdf"
