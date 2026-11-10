# Uso (a partir da raiz do projeto):
#   gnuplot -e "csvfile='benchmark_x/results.csv'; outdir='plots'" scripts/plot_result.gp
#
# Gera:
#   plots/*.png            + plots/charts.pdf          (run atual; inclui roofline.png)
#   plots/cmp_*.png        + plots/charts_compare.pdf  (run atual vs compare/best_results.csv)
#
# FLOPs: usa a precisão (f64, f32 ou f16) com maior valor no CSV; a grandeza aparece
# no título/legenda. Se as duas runs da comparação usarem grandezas diferentes, os
# gráficos de FLOPs aparecem lado a lado (em vez de sobrepostos) na mesma página.
#
# Roofline: teto de memória = bw_peak (GB/s); teto de cálculo = pico da precisão a
# 2.2 GHz escalado pela frequência (freq_GHz) da melhor run (menor tempo).
#
# Se algum "seconds elapsed" da run atual (qualquer nº de threads) for inferior a
# todos os de compare/best_results.csv, pergunta o nome da run antiga, guarda
# o best_results.csv antigo em compare/best_history/<nome>.csv e passa a run
# atual a compare/best_results.csv.
#
# Opcional: -e "compare_dir='compare'; bestfile='compare/best_results.csv'; bw_peak=1024"
# Requer gnuplot >= 5.2, bash e awk/sort.

if (!exists("csvfile")) csvfile = "results.csv"
if (!exists("outdir"))  outdir  = "plots"
if (!exists("bw_peak")) bw_peak = 1024.0      # GB/s (HBM2 do A64FX)
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

# cores: atual (azul/verde) vs melhor anterior (laranja/rosa)
c_cur1 = "#0072B2"
c_bst1 = "#D55E00"
c_cur2 = "#009E73"
c_bst2 = "#CC79A7"

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
# Versões com ficheiro explícito (sufixo f) e atalhos para o csvfile atual
# ------------------------------------------------------------
filtf(f,k,m) = sprintf("awk -F, -v OFS=, -v k='%s' -v m='%s' 'NR>1 && $2==k && $3==m {print $1,$4}' %s | sort -t, -k1,1n", k, m, f)
srcf(f,k,m)  = "< " . filtf(f,k,m)
cntf(f,k,m)  = real(system(filtf(f,k,m) . " | wc -l"))

# mínimo e máximo calculados diretamente do CSV (independentes de ranges ativos)
aminf(f,k,m) = real(system(sprintf("awk -F, -v k='%s' -v m='%s' 'NR>1 && $2==k && $3==m {v=$4+0; if(n++==0||v<mn)mn=v} END{printf \"%%.12g\", mn}' %s", k, m, f)))
amaxf(f,k,m) = real(system(sprintf("awk -F, -v k='%s' -v m='%s' 'NR>1 && $2==k && $3==m {v=$4+0; if(n++==0||v>mx)mx=v} END{printf \"%%.12g\", mx}' %s", k, m, f)))
# nº de threads onde a métrica é mínima
argminf(f,k,m) = real(system(sprintf("awk -F, -v k='%s' -v m='%s' 'NR>1 && $2==k && $3==m {v=$4+0; if(n++==0||v<mn){mn=v; t=$1}} END{printf \"%%s\", t}' %s", k, m, f)))
# valor da métrica para um dado nº de threads
valatf(f,k,m,t) = real(system(sprintf("awk -F, -v k='%s' -v m='%s' -v t=%d 'NR>1 && $2==k && $3==m && $1+0==t {printf \"%%.12g\", $4+0}' %s", k, m, int(t), f)))

mn2(a,b) = (a < b) ? a : b
mx2(a,b) = (a > b) ? a : b

filt(k,m) = filtf(csvfile,k,m)
src(k,m)  = srcf(csvfile,k,m)
cnt(k,m)  = cntf(csvfile,k,m)
amin(k,m) = aminf(csvfile,k,m)
amax(k,m) = amaxf(csvfile,k,m)

# ------------------------------------------------------------
# Grandeza de FLOPs: a precisão (f64/f32/f16) com maior valor no CSV.
# CSVs antigos só têm "FLOPs" (dp + 2*fma) -> tratado como "legacy".
# ------------------------------------------------------------
ft_awk = 'NR>1 && $2=="derived" && $3 ~ /^FLOPs_f(64|32|16)$/ {v=$4+0; if(v>mx[$3]) mx[$3]=v} END{bm=-1; for(k in mx) if(mx[k]>bm){bm=mx[k]; b=k}; sub(/FLOPs_/,"",b); print b}'
ftypef(f)  = system("awk -F, '" . ft_awk . "' " . f)
fl_type(f) = (ftypef(f) eq "") ? "legacy" : ftypef(f)
fmet(t)    = (t eq "legacy") ? "FLOPs" : "FLOPs_" . t
flab(t)    = (t eq "legacy") ? "FLOPs (legado: dp+2*fma)" : "FLOPs (" . t . ")"
# pico a 2.2 GHz em GFLOP/s (48 cores): f64 3.3792, f32 6.7584, f16 13.5168 TFLOP/s
peak22(t)  = (t eq "f64") ? 3379.2 : ((t eq "f32") ? 6758.4 : 13516.8)

ftype = fl_type(csvfile)

# ------------------------------------------------------------
# Speedup: T(menor nº de threads) / T(n), calculado a partir do tempo
# ------------------------------------------------------------
has_elapsed = cnt("perf", "seconds elapsed")

spd_awk = 'NR>1 && $2=="perf" && $3=="seconds elapsed" {t[$1]=$4+0; if(mn==""||$1+0<mn) mn=$1+0} END{for(n in t) printf "%s,%.6f\n", n, t[mn]/t[n]}'
spdf(f)  = "awk -F, '" . spd_awk . "' " . f . " | sort -t, -k1,1n"
spd_cmd = spdf(csvfile)
spd_src = "< " . spd_cmd

id_awk  = 'NR>1 && $2=="perf" && $3=="seconds elapsed" {t[$1]=1; if(mn==""||$1+0<mn) mn=$1+0} END{for(n in t) printf "%s,%.6f\n", n, n/mn}'
ideal_src = "< awk -F, '" . id_awk . "' " . csvfile . " | sort -t, -k1,1n"

# ------------------------------------------------------------
# Roofline: pré-cálculos (pontos: threads, intensidade aritmética, GFLOP/s)
# AI = FLOPs / bytes de memória ; GFLOP/s = FLOPs / tempo / 1e9
# ------------------------------------------------------------
roof_awk = 'NR>1 && $2=="derived" && $3==F {f[$1]=$4+0} NR>1 && $2=="derived" && $3=="mem_bytes" {b[$1]=$4+0} NR>1 && $2=="perf" && $3=="seconds elapsed" {t[$1]=$4+0} END{for(n in t) if(f[n]>0 && b[n]>0 && t[n]>0) printf "%s,%.9g,%.9g\n", n, f[n]/b[n], f[n]/t[n]/1e9}'
colmin(cmd,c) = real(system(cmd . sprintf(" | awk -F, '{v=$%d+0; if(NR==1||v<m)m=v} END{printf \"%%.12g\", m}'", c)))
colmax(cmd,c) = real(system(cmd . sprintf(" | awk -F, '{v=$%d+0; if(NR==1||v>m)m=v} END{printf \"%%.12g\", m}'", c)))

has_roof = 0
if (ftype ne "legacy" && has_elapsed > 0 && cnt("derived", "mem_bytes") > 0 && cnt("derived", fmet(ftype)) > 0) {
    roof_cmd = "awk -F, -v F='" . fmet(ftype) . "' '" . roof_awk . "' " . csvfile . " | sort -t, -k1,1n"
    roof_src = "< " . roof_cmd
    if (real(system(roof_cmd . " | wc -l")) > 0) {
        has_roof = 1
        rbest_th = argminf(csvfile, "perf", "seconds elapsed")
        if (cnt("derived", "freq_GHz") > 0) {
            freq_best = valatf(csvfile, "derived", "freq_GHz", rbest_th)
        } else {
            print "AVISO: sem freq_GHz no CSV - a usar 2.2 GHz no teto de cálculo"
            freq_best = 2.2
        }
        peak  = peak22(ftype) * freq_best / 2.2       # GFLOP/s
        ridge = peak / bw_peak                        # FLOP/byte
        roofline(x) = (bw_peak*x < peak) ? bw_peak*x : peak
        xmin_r = mn2(colmin(roof_cmd, 2), ridge) / 30.0
        xmax_r = mx2(colmax(roof_cmd, 2), ridge) * 3.0
        ymin_r = colmin(roof_cmd, 3) / 3.0
        ymax_r = peak * 2.0

        # rótulo da reta de largura de banda: posição e ângulo aproximado no ecrã
        xdec = log10(xmax_r/xmin_r)
        ydec = log10(ymax_r/ymin_r)
        bw_ang  = atan2(597.0/ydec, 1068.0/xdec) * 180.0/pi
        bw_xlab = mx2(xmin_r * (xmax_r/xmin_r)**0.10, 2.5*ymin_r/bw_peak)
        bw_xlab = mn2(bw_xlab, ridge/2.0)

        # verificação de coerência: pontos acima do roofline => medição inconsistente
        n_above = real(system(roof_cmd . sprintf(" | awk -F, -v bw=%.12g -v pk=%.12g '{r=bw*$2; if(r>pk)r=pk; if($3>r*1.001)n++} END{printf \"%%d\", n+0}'", bw_peak, peak)))
        if (n_above > 0) {
            print sprintf("AVISO: %d ponto(s) acima do roofline - impossível fisicamente: verifica mem_bytes (bus_*), FLOPs ou a frequência", n_above)
        }
    }
}
if (!has_roof) print "AVISO: sem dados para o roofline (faltam FLOPs_*, mem_bytes ou tempo) - gráfico ignorado"

# ------------------------------------------------------------
# Definição dos gráficos (metric2 vazio => série única)
# ------------------------------------------------------------
NCH = 8
array ch_title[NCH]
array ch_ylabel[NCH]
array ch_file[NCH]
array ch_kind1[NCH]
array ch_metric1[NCH]
array ch_kind2[NCH]
array ch_metric2[NCH]
array ch_legend[NCH]

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

# FLOPs: precisão com maior valor (a grandeza vai no título, no eixo e na legenda)
ch_title[5]=flab(ftype);               ch_ylabel[5]=flab(ftype)
ch_file[5]="flops";                    ch_kind1[5]="derived"; ch_metric1[5]=fmet(ftype)
ch_kind2[5]=""; ch_metric2[5]=""

ch_title[6]="Tempo de execução";       ch_ylabel[6]="Segundos"
ch_file[6]="elapsed";                  ch_kind1[6]="perf"; ch_metric1[6]="seconds elapsed"
ch_kind2[6]=""; ch_metric2[6]=""

ch_title[7]="Largura de banda de memória"; ch_ylabel[7]="GB/s"
ch_file[7]="mem_bandwidth";            ch_kind1[7]="derived"; ch_metric1[7]="mem_bw_GBs"
ch_kind2[7]=""; ch_metric2[7]=""

ch_title[8]="Frequência média";        ch_ylabel[8]="GHz"
ch_file[8]="frequency";                ch_kind1[8]="derived"; ch_metric1[8]="freq_GHz"
ch_kind2[8]=""; ch_metric2[8]=""

do for [i=1:NCH] { ch_legend[i] = ch_metric1[i] }
ch_legend[5] = flab(ftype)

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

        # Tempo de execução: SEMPRE linear (nunca log) e com valor y em cada ponto
        if (ch_file[i] eq "elapsed") {
            set yrange [0 : (ymax > 0 ? ymax*1.25 : 1)]
            set format y "%.4g"
        } else if (ratio >= 20) {
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
            plot f1 using 1:2 with linespoints lw 2 pt 7 title ch_legend[i], \
                 f1 using 1:2:1 with labels offset 0,1 font ",10" notitle, \
                 f2 using 1:2 with linespoints lw 2 pt 5 title ch_metric2[i], \
                 f2 using 1:2:1 with labels offset 0,-1 font ",10" notitle
        } else if (ch_file[i] eq "elapsed") {
            # valor y (segundos) assinalado em cada ponto
            plot f1 using 1:2 with linespoints lw 2 pt 7 title ch_legend[i], \
                 f1 using 1:2:(sprintf("%.4g s", $2)) with labels offset 0,1 font ",10" notitle
        } else {
            plot f1 using 1:2 with linespoints lw 2 pt 7 title ch_legend[i], \
                 f1 using 1:2:1 with labels offset 0,1 font ",10" notitle
        }
    }
    # --------------------------------------------------------
    # Ganho (speedup) = T(ref) / T(n), com ref = menor nº de threads
    # Percentagem de eficiência = (speedup / n_threads) × 100%
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
            spd_src using 1:2:(sprintf("%.0f%%", $2/$1*100)) \
                with labels offset 1.3,0.9 font ",10" tc rgb "#222222" notitle
    }

    # --------------------------------------------------------
    # Roofline (log-log): x = intensidade aritmética, y = GFLOP/s
    # Um ponto por nº de threads (nº por baixo); melhor tempo com outra cor;
    # ridge point a tracejado com a intensidade aritmética em baixo.
    # --------------------------------------------------------
    if (has_roof) {
        if (pass == 1) { set output outdir . "/roofline.png" }
        set xtics auto
        set logscale x 10
        set logscale y 10
        set xrange [xmin_r : xmax_r]
        set yrange [ymin_r : ymax_r]
        set format x "10^{%L}"
        set format y "10^{%L}"
        set samples 1000
        set title sprintf("Roofline (%s)", ftype)
        set xlabel "Intensidade aritmética (FLOP/byte)"
        set ylabel sprintf("Desempenho (GFLOP/s, %s)", ftype)

        set arrow 1 from ridge, ymin_r to ridge, peak nohead dt 2 lw 2 lc rgb "gray40"
        set label 1 sprintf("ridge: %.2f FLOP/byte", ridge) at ridge, ymin_r left offset 0.6,1.2 front textcolor rgb "gray30"
        set label 2 sprintf("memória: %g GB/s", bw_peak) at bw_xlab, bw_peak*bw_xlab rotate by bw_ang center offset 0,1.0 front textcolor rgb "black"
        set label 3 sprintf("pico de cálculo (%s): %.2f TFLOP/s a %.1f GHz", ftype, peak/1000.0, freq_best) at xmax_r/1.1, peak right offset 0,1.0 front textcolor rgb "black"

        plot roofline(x) with lines lw 3 lc rgb "black" \
                 title sprintf("Roofline %s: %.2f TFLOP/s a %.1f GHz | %g GB/s", ftype, peak/1000.0, freq_best, bw_peak), \
             roof_src using 2:3 with points pt 7 ps 1.6 lc rgb c_cur1 title sprintf("Threads (%s)", ftype), \
             roof_src using 2:($1==rbest_th ? $3 : 1/0) with points pt 13 ps 2.4 lc rgb c_bst1 \
                 title sprintf("Melhor tempo (%d threads)", rbest_th), \
             roof_src using 2:($1!=rbest_th ? $3 : 1/0):1 with labels offset 0,-1.3 font ",10" tc rgb c_cur1 notitle, \
             roof_src using 2:($1==rbest_th ? $3 : 1/0):1 with labels offset 0,-1.5 font ",11" tc rgb c_bst1 notitle

        unset arrow 1
        unset label 1
        unset label 2
        unset label 3

        # restaurar eixos dos gráficos por nº de threads
        unset logscale y
        set logscale x 2
        set xrange [tmin/1.25 : tmax*1.25]
        set format x "%g"
        eval "set xtics (" . threads . ")"
        set xlabel "Número de threads"
    }
    unset output
}

print "PNGs gerados em: " . outdir
print "PDF único: " . outdir . "/charts.pdf"

# ============================================================
# COMPARAÇÃO com o melhor resultado anterior
# ============================================================
if (!exists("compare_dir")) compare_dir = "compare"
if (!exists("bestfile"))    bestfile    = compare_dir . "/best_results.csv"
histdir = compare_dir . "/best_history"

have_best = (system("test -f '" . bestfile . "' && echo 1 || echo 0") eq "1")

if (!have_best) {
    print "AVISO: " . bestfile . " não existe - a guardar esta run como primeiro melhor resultado."
    system("mkdir -p '" . histdir . "'")
    system("cp '" . csvfile . "' '" . bestfile . "'")
} else {
    cur_n  = cntf(csvfile,  "perf", "seconds elapsed")
    best_n = cntf(bestfile, "perf", "seconds elapsed")

    if (cur_n == 0 || best_n == 0) {
        print "AVISO: sem 'seconds elapsed' em " . ((cur_n == 0) ? csvfile : bestfile) . " - comparação ignorada"
    } else {
        # ---- eixo X: união das threads das duas runs ----
        allthr    = "awk -F, 'FNR>1 {print $1}' " . csvfile . " " . bestfile
        threads_c = system(allthr . " | sort -un | paste -sd, -")
        tmin_c    = real(system(allthr . " | sort -n | head -1"))
        tmax_c    = real(system(allthr . " | sort -n | tail -1"))

        set logscale x 2
        set xrange [tmin_c/1.25 : tmax_c*1.25]
        set format x "%g"
        eval "set xtics (" . threads_c . ")"

        # grandeza de FLOPs de cada run
        ft_c = ftype
        ft_b = fl_type(bestfile)
        fm_c = fmet(ft_c)
        fm_b = fmet(ft_b)
        flops_differ = (ft_c ne ft_b)
        if (flops_differ) {
            print "AVISO: grandezas de FLOPs diferentes (atual: " . ft_c . ", melhor: " . ft_b . ") - gráficos lado a lado"
        }

        do for [pass=1:2] {
            if (pass == 1) {
                set terminal pngcairo size 1200,750 enhanced font "Arial,12"
            } else {
                set terminal pdfcairo size 12in,7.5in enhanced color solid font ",12"
                set output outdir . "/charts_compare.pdf"
            }

            do for [i=1:NCH] {
                # ---- FLOPs com grandezas diferentes: dois gráficos lado a lado ----
                if (ch_file[i] eq "flops" && flops_differ) {
                    if (cntf(csvfile, "derived", fm_c) == 0 || cntf(bestfile, "derived", fm_b) == 0) {
                        print "AVISO: sem dados de FLOPs nas duas runs - gráfico ignorado"
                        continue
                    }
                    if (pass == 1) { set output outdir . "/cmp_flops.png" }
                    unset lmargin
                    unset rmargin
                    set multiplot layout 1,2 title "FLOPs: atual vs melhor anterior (grandezas diferentes)"
                    do for [side=1:2] {
                        ff = (side == 1) ? csvfile : bestfile
                        mm = (side == 1) ? fm_c : fm_b
                        ll = (side == 1) ? flab(ft_c) : flab(ft_b)
                        cc = (side == 1) ? c_cur1 : c_bst1
                        pp = (side == 1) ? 7 : 5
                        nm = (side == 1) ? "Atual" : "Melhor anterior"
                        fsrc = srcf(ff, "derived", mm)

                        unset logscale y
                        sy1 = aminf(ff, "derived", mm)
                        sy2 = amaxf(ff, "derived", mm)
                        sratio = (sy1 > 0) ? sy2/sy1 : 1e9
                        if (sratio >= 20) {
                            set logscale y 10
                            set yrange [sy1/2 : sy2*3]
                            set format y "10^{%L}"
                        } else {
                            set yrange [0 : (sy2 > 0 ? sy2*1.2 : 1)]
                            set format y "%.3g"
                        }
                        set title nm . ": " . ll
                        set ylabel ll
                        plot fsrc using 1:2 with linespoints lw 2 pt (pp) lc rgb cc title nm . " - " . ll, \
                             fsrc using 1:2:1 with labels offset 0,1 font ",10" tc rgb cc notitle
                    }
                    unset multiplot
                    unset logscale y
                    set lmargin 14
                    set rmargin 4
                    continue
                }

                k1 = ch_kind1[i]
                m1 = ch_metric1[i]
                hc1 = cntf(csvfile,  k1, m1)
                hb1 = cntf(bestfile, k1, m1)
                if (hc1 == 0 || hb1 == 0) {
                    print "AVISO: sem dados nas duas runs para '" . ch_title[i] . "' - gráfico de comparação ignorado"
                    continue
                }
                cur1 = srcf(csvfile,  k1, m1)
                bst1 = srcf(bestfile, k1, m1)

                # grandeza dos FLOPs na legenda (as duas runs têm a mesma aqui)
                cmp_sfx = (ch_file[i] eq "flops") ? " (" . ft_c . ")" : ""

                has2c = 0
                has2b = 0
                if (ch_metric2[i] ne "") {
                    k2 = ch_kind2[i]
                    m2 = ch_metric2[i]
                    has2c = cntf(csvfile,  k2, m2)
                    has2b = cntf(bestfile, k2, m2)
                    cur2 = srcf(csvfile,  k2, m2)
                    bst2 = srcf(bestfile, k2, m2)
                }
                has2 = (has2c > 0 && has2b > 0)

                # ---- escala Y comum às duas runs ----
                unset logscale y
                ymin = aminf(csvfile, k1, m1)
                ymax = amaxf(csvfile, k1, m1)
                ymin_b = aminf(bestfile, k1, m1)
                ymax_b = amaxf(bestfile, k1, m1)
                ymin = (ymin_b < ymin) ? ymin_b : ymin
                ymax = (ymax_b > ymax) ? ymax_b : ymax
                if (has2) {
                    ymin2 = (aminf(csvfile, k2, m2) < aminf(bestfile, k2, m2)) ? aminf(csvfile, k2, m2) : aminf(bestfile, k2, m2)
                    ymax2 = (amaxf(csvfile, k2, m2) > amaxf(bestfile, k2, m2)) ? amaxf(csvfile, k2, m2) : amaxf(bestfile, k2, m2)
                    ymin = (ymin2 < ymin) ? ymin2 : ymin
                    ymax = (ymax2 > ymax) ? ymax2 : ymax
                }
                ratio = (ymin > 0) ? ymax/ymin : 1e9

                # Tempo de execução: SEMPRE linear (nunca log)
                if (ch_file[i] eq "elapsed") {
                    set yrange [0 : (ymax > 0 ? ymax*1.25 : 1)]
                    set format y "%.4g"
                } else if (ratio >= 20) {
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

                if (pass == 1) { set output outdir . "/cmp_" . ch_file[i] . ".png" }
                set title ch_title[i] . " - atual vs melhor anterior"
                set ylabel ch_ylabel[i]

                if (has2) {
                    plot cur1 using 1:2 with linespoints lw 2 pt 7 lc rgb c_cur1 title "Atual: " . m1, \
                         cur1 using 1:2:1 with labels offset 0,1 font ",10" tc rgb c_cur1 notitle, \
                         bst1 using 1:2 with linespoints lw 2 pt 5 dt 2 lc rgb c_bst1 title "Melhor: " . m1, \
                         bst1 using 1:2:1 with labels offset 0,-1 font ",10" tc rgb c_bst1 notitle, \
                         cur2 using 1:2 with linespoints lw 2 pt 9 lc rgb c_cur2 title "Atual: " . m2, \
                         bst2 using 1:2 with linespoints lw 2 pt 11 dt 2 lc rgb c_bst2 title "Melhor: " . m2
                } else if (ch_file[i] eq "elapsed") {
                    # valor y (segundos) em cada ponto, para as duas runs
                    plot cur1 using 1:2 with linespoints lw 2 pt 7 lc rgb c_cur1 title "Atual", \
                         cur1 using 1:2:(sprintf("%.4g s", $2)) with labels offset 0,1 font ",10" tc rgb c_cur1 notitle, \
                         bst1 using 1:2 with linespoints lw 2 pt 5 dt 2 lc rgb c_bst1 title "Melhor anterior", \
                         bst1 using 1:2:(sprintf("%.4g s", $2)) with labels offset 0,-1 font ",10" tc rgb c_bst1 notitle
                } else {
                    plot cur1 using 1:2 with linespoints lw 2 pt 7 lc rgb c_cur1 title "Atual" . cmp_sfx, \
                         cur1 using 1:2:1 with labels offset 0,1 font ",10" tc rgb c_cur1 notitle, \
                         bst1 using 1:2 with linespoints lw 2 pt 5 dt 2 lc rgb c_bst1 title "Melhor anterior" . cmp_sfx, \
                         bst1 using 1:2:1 with labels offset 0,-1 font ",10" tc rgb c_bst1 notitle
                }
            }

            # ----------------------------------------------------
            # Speedup: cada run relativa ao seu próprio menor nº de threads
            # + percentagem de eficiência (speedup/n) ao lado de cada ponto
            # ----------------------------------------------------
            if (pass == 1) { set output outdir . "/cmp_speedup.png" }
            unset logscale y
            ymax_c = real(system(spdf(csvfile)  . " | awk -F, '{if(NR==1||$2>m)m=$2} END{print m}'"))
            ymax_b = real(system(spdf(bestfile) . " | awk -F, '{if(NR==1||$2>m)m=$2} END{print m}'"))
            ymax_i = tmax / tmin
            ytop = ymax_c
            ytop = (ymax_b > ytop) ? ymax_b : ytop
            ytop = (ymax_i > ytop) ? ymax_i : ytop
            set yrange [0 : ytop*1.15]
            set format y "%.3g"
            set title "Ganho (speedup) - atual vs melhor anterior"
            set ylabel "Speedup = T_{ref} / T_n"

            plot ideal_src using 1:2 with lines dt 2 lw 2 lc rgb "gray40" title "Ideal (linear)", \
                 "< " . spdf(csvfile) using 1:2 with linespoints lw 2 pt 7 lc rgb c_cur1 title "Atual", \
                 "< " . spdf(csvfile) using 1:2:(sprintf("%.0f%%", $2/$1*100)) \
                     with labels offset 1.3,0.9 font ",10" tc rgb c_cur1 notitle, \
                 "< " . spdf(bestfile) using 1:2 with linespoints lw 2 pt 5 dt 2 lc rgb c_bst1 title "Melhor anterior", \
                 "< " . spdf(bestfile) using 1:2:(sprintf("%.0f%%", $2/$1*100)) \
                     with labels offset 1.3,-0.9 font ",10" tc rgb c_bst1 notitle

            unset output
        }

        print "PNGs de comparação gerados em: " . outdir . "/cmp_*.png"
        print "PDF de comparação: " . outdir . "/charts_compare.pdf"

        # ----------------------------------------------------
        # Novo melhor resultado?
        # (só depois dos gráficos, para compararem com o melhor ANTERIOR)
        # ----------------------------------------------------
        cur_t   = aminf(csvfile,  "perf", "seconds elapsed")
        cur_th  = argminf(csvfile, "perf", "seconds elapsed")
        best_t  = aminf(bestfile, "perf", "seconds elapsed")
        best_th = argminf(bestfile, "perf", "seconds elapsed")

        if (cur_t < best_t) {
            print ""
            print sprintf("NOVO MELHOR RESULTADO: %.6f s / %d Threads", cur_t, int(cur_th))
            print sprintf("(anterior: %.6f s / %d Threads)", best_t, int(best_th))

            name = system("bash -c 'n=\"\"; printf \"NOME DA RUN ANTIGA: \" > /dev/tty 2>/dev/null; read -r n < /dev/tty 2>/dev/null; printf \"%s\" \"$n\" | tr -c \"A-Za-z0-9._-\" \"_\"'")
            stamp = strftime("%Y%m%d_%H%M%S", time(0))
            if (strlen(name) == 0) {
                name = "run_" . stamp
                print "AVISO: nome não fornecido - a usar '" . name . "'"
            }

            system("mkdir -p '" . histdir . "'")
            histfile = histdir . "/" . name . ".csv"
            if (system("test -e '" . histfile . "' && echo 1 || echo 0") eq "1") {
                histfile = histdir . "/" . name . "_" . stamp . ".csv"
                print "AVISO: já existe um ficheiro com esse nome - a gravar como " . histfile
            }

            system("cp '" . bestfile . "' '" . histfile . "'")
            system("cp '" . csvfile  . "' '" . bestfile . "'")
            print "Run antiga guardada em: " . histfile
            print "Novo melhor resultado guardado em: " . bestfile
        } else {
            print sprintf("Sem novo melhor resultado: atual %.6f s / %d Threads | melhor %.6f s / %d Threads", cur_t, int(cur_th), best_t, int(best_th))
        }
    }
}
