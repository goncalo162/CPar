
# Uso:
#   gnuplot -e "csvfile='results.csv'; format='png'" plot_results.gp
#   gnuplot -e "csvfile='results.csv'; format='latex'" plot_results.gp
#
# O CSV deve ter as colunas:
# threads,kind,metric,value

if (!exists("csvfile")) csvfile = "results.csv"
if (!exists("outdir")) outdir = "plots"
if (!exists("format")) format = "png"

if (format ne "png" && format ne "latex") {
    print "Erro: format deve ser png ou latex"
    exit
}

system("mkdir -p '" . outdir . "'")

set datafile separator ","
set datafile columnheaders
set grid
set border linewidth 1.2
set xlabel "Número de threads"
set ylabel "Valor"
set xtics (1, 2, 4, 8, 16, 32, 48)
set format x "%g"
set logscale x 2
set key off
set pointsize 1.2
set lmargin 12
set rmargin 3
set tmargin 3
set bmargin 4

if (format eq "png") {
    set terminal pngcairo size 1200,750 enhanced font "Arial,12"
    extension = ".png"
} else {
    # Gera ficheiros LaTeX autónomos com o terminal TikZ do Gnuplot.
    set terminal tikz standalone size 12cm,7cm
    extension = ".tex"
}

# ------------------------------------------------------------
# Gráficos do output
# ------------------------------------------------------------
array out_metric[7]
array out_file[7]

out_metric[1] = "Total Time (s)"
out_file[1] = "output_Total_Time_s"

out_metric[2] = "T (K)"
out_file[2] = "output_T_K"

out_metric[3] = "P (Pa)"
out_file[3] = "output_P_Pa"

out_metric[4] = "PV/nT (J/(mol K))"
out_file[4] = "output_PV_nT_J_per_mol_K"

out_metric[5] = "Z"
out_file[5] = "output_Z"

out_metric[6] = "V (m^3)"
out_file[6] = "output_V_m3"

out_metric[7] = "N"
out_file[7] = "output_N"

do for [i=1:7] {
    metric = out_metric[i]
    filename = outdir . "/" . out_file[i] . extension

    set output filename
    set title metric

    plot csvfile using \
        (strcol(2) eq "output" && strcol(3) eq metric ? \
        real(column(1)) : 1/0):4 \
        with linespoints linewidth 2 pointtype 7
    unset output
}

# ------------------------------------------------------------
# Gráficos de perf
# ------------------------------------------------------------
array perf_metric[6]
array perf_file[6]

perf_metric[1] = "cycles"
perf_file[1] = "perf_cycles"

perf_metric[2] = "instructions"
perf_file[2] = "perf_instructions"

perf_metric[3] = "branches"
perf_file[3] = "perf_branches"

perf_metric[4] = "branch-misses"
perf_file[4] = "perf_branch-misses"

perf_metric[5] = "L1-dcache-loads"
perf_file[5] = "perf_L1-dcache-loads"

perf_metric[6] = "L1-dcache-load-misses"
perf_file[6] = "perf_L1-dcache-load-misses"

do for [i=1:6] {
    metric = perf_metric[i]
    filename = outdir . "/" . perf_file[i] . extension

    set output filename
    set title metric

    plot csvfile using \
        (strcol(2) eq "perf" && strcol(3) eq metric ? \
        real(column(1)) : 1/0):4 \
        with linespoints linewidth 2 pointtype 7
    unset output
}

print "Gráficos gerados em: " . outdir