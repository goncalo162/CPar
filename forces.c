/*
    forces.c - kernels O(N^2) do MD: forças (computeAccelerations) e energia
    potencial (Potential).

    Compilado à parte com -mlow-precision-div (ver Makefile): a divisão 1/r2
    passa a ser uma estimativa do inverso (frecpe) + iterações de Newton, muito
    mais rápida no A64FX do que a divisão SVE. A essa aproximação (~32 bits)
    junta-se uma iteração de Newton escrita no código, que recupera a precisão
    total do double.

    O resto do programa (MD.cpp) é compilado SEM essa flag, para que as
    divisões da pressão, temperatura, etc. continuem exatas.
*/
#include "md.h"
#include <omp.h>
#include <arm_sve.h>
/* Energia potencial das posições do último computeAccelerations(). Calcula-se no
   mesmo ciclo das forças (mesmos pares, mesmo 1/r2) e o Potential() só a devolve:
   no ciclo principal as posições não mudam entre computeAccelerations() (dentro do
   VelocityVerlet) e Potential(). */
static double PE_atual = 0.0;

/* Tamanho do bloco de j: os temporários (2 x BLK doubles = 8 KB) ficam na L1 (64 KB). */
#ifndef BLK
#define BLK 512
#endif

#define MAX_THREADS_F 192
static double pot_parcial[MAX_THREADS_F][32] __attribute__((aligned(256)));

void computeAccelerations(void)
{
    double pot = 0.0;
    int nthreads = 1;

#pragma omp parallel
    {
        double pot_t = 0.0; /* soma local desta thread */

        /* Temporários privados de cada thread, para as duas partículas (a = i, b = i+1).
           Alinhados a 16 KB (período dos conjuntos da L1 do A64FX): ficam nos mesmos
           conjuntos da cache em todas as threads, incluindo a master. */
        struct
        {
            double r2a[BLK], r2b[BLK], inva[BLK], invb[BLK];
        } tmp __attribute__((aligned(16384)));
        double *const r2a = tmp.r2a, *const r2b = tmp.r2b;
        double *const inva = tmp.inva, *const invb = tmp.invb;

        /* Tiling em i: cada iteração trata duas partículas (i e i+1) contra o mesmo
           bloco de j. Cada rx/ry/rz[j] carregado serve as duas (metade dos loads da L2
           por par) e cada partícula tem os seus acumuladores (duas cadeias de soma
           independentes na fase 3). */
#pragma omp for schedule(static) nowait
        for (int i = 0; i < N; i += 2)
        {
            const int tem_b = (i + 1 < N);    /* N ímpar: a última iteração só tem i */
            const int ib = tem_b ? i + 1 : i; /* sem b, repete i e não guarda o resultado */

            const double xa = rx[i], ya = ry[i], za = rz[i];
            const double xb = rx[ib], yb = ry[ib], zb = rz[ib];
            double fxa = 0.0, fya = 0.0, fza = 0.0, ua = 0.0;
            double fxb = 0.0, fyb = 0.0, fzb = 0.0, ub = 0.0;

            for (int j0 = 0; j0 < N; j0 += BLK)
            {
                const int n = (N - j0 < BLK) ? N - j0 : BLK;

                /* fase 1: distância ao quadrado, rx/ry/rz[j] lidos uma vez para as duas */
                for (int k = 0; k < n; k++)
                {
                    const double xj = rx[j0 + k], yj = ry[j0 + k], zj = rz[j0 + k];
                    const double dxa = xa - xj, dya = ya - yj, dza = za - zj;
                    const double dxb = xb - xj, dyb = yb - yj, dzb = zb - zj;
                    r2a[k] = dxa * dxa + dya * dya + dza * dza;
                    r2b[k] = dxb * dxb + dyb * dyb + dzb * dzb;
                }

                /* fase 2: 1/r2 = x0·(1+e)(1+e²)(1+e⁴), com x0 = frecpe(r2) e e = 1 - r2·x0
                   (cadeia de 5 em vez de 7); 2 vetores por volta (k e k+vl):
                   4 cadeias independentes */
                {
                    const svbool_t todos = svptrue_b64();
                    const svfloat64_t um = svdup_f64(1.0);
                    const int vl = (int)svcntd();
                    for (int k = 0; k < n; k += 2 * vl)
                    {
                        const svbool_t p0 = svwhilelt_b64(k, n), p1 = svwhilelt_b64(k + vl, n);
                        const svfloat64_t ra0 = svld1(p0, r2a + k), rb0 = svld1(p0, r2b + k);
                        const svfloat64_t ra1 = svld1(p1, r2a + k + vl), rb1 = svld1(p1, r2b + k + vl);
                        const svfloat64_t xa0 = svrecpe(ra0), xb0 = svrecpe(rb0);
                        const svfloat64_t xa1 = svrecpe(ra1), xb1 = svrecpe(rb1);
                        const svfloat64_t ea0 = svmsb_x(todos, ra0, xa0, um), eb0 = svmsb_x(todos, rb0, xb0, um);
                        const svfloat64_t ea1 = svmsb_x(todos, ra1, xa1, um), eb1 = svmsb_x(todos, rb1, xb1, um);
                        const svfloat64_t ea0_2 = svmul_x(todos, ea0, ea0), eb0_2 = svmul_x(todos, eb0, eb0);
                        const svfloat64_t ea1_2 = svmul_x(todos, ea1, ea1), eb1_2 = svmul_x(todos, eb1, eb1);
                        svfloat64_t pa0 = svmla_x(todos, xa0, xa0, ea0), pb0 = svmla_x(todos, xb0, xb0, eb0);
                        svfloat64_t pa1 = svmla_x(todos, xa1, xa1, ea1), pb1 = svmla_x(todos, xb1, xb1, eb1);
                        const svfloat64_t ea0_4 = svmul_x(todos, ea0_2, ea0_2), eb0_4 = svmul_x(todos, eb0_2, eb0_2);
                        const svfloat64_t ea1_4 = svmul_x(todos, ea1_2, ea1_2), eb1_4 = svmul_x(todos, eb1_2, eb1_2);
                        pa0 = svmla_x(todos, pa0, pa0, ea0_2);
                        pb0 = svmla_x(todos, pb0, pb0, eb0_2);
                        pa1 = svmla_x(todos, pa1, pa1, ea1_2);
                        pb1 = svmla_x(todos, pb1, pb1, eb1_2);
                        pa0 = svmla_x(todos, pa0, pa0, ea0_4);
                        pb0 = svmla_x(todos, pb0, pb0, eb0_4);
                        pa1 = svmla_x(todos, pa1, pa1, ea1_4);
                        pb1 = svmla_x(todos, pb1, pb1, eb1_4);
                        svst1(p0, inva + k, pa0);
                        svst1(p0, invb + k, pb0);
                        svst1(p1, inva + k + vl, pa1);
                        svst1(p1, invb + k + vl, pb1);
                    }
                }
                /* par da partícula consigo própria (r2 = 0): só existe no bloco que
                   contém i (e ib); anula-se aqui, fora do ciclo, em vez de testar r2 > 0
                   em todos os pares */
                if (i >= j0 && i < j0 + n)
                    inva[i - j0] = 0.0;
                if (ib >= j0 && ib < j0 + n)
                    invb[ib - j0] = 0.0;

                /* fase 3: Lennard-Jones (sigma = epsilon = 1), potências em árvore,
                   o 24 fica para o fim; acumuladores separados para a e b */
                for (int k = 0; k < n; k++)
                {
                    const double xj = rx[j0 + k], yj = ry[j0 + k], zj = rz[j0 + k];

                    const double i2a = inva[k];
                    const double i4a = i2a * i2a, i6a = i4a * i2a, i8a = i4a * i4a;
                    const double fa = i8a * ((i2a + i2a) * i4a - 1.0);

                    const double i2b = invb[k];
                    const double i4b = i2b * i2b, i6b = i4b * i2b, i8b = i4b * i4b;
                    const double fb = i8b * ((i2b + i2b) * i4b - 1.0);

                    ua += i6a * (i6a - 1.0);
                    ub += i6b * (i6b - 1.0);
                    fxa += (xa - xj) * fa;
                    fxb += (xb - xj) * fb;
                    fya += (ya - yj) * fa;
                    fyb += (yb - yj) * fb;
                    fza += (za - zj) * fa;
                    fzb += (zb - zj) * fb;
                }
            }

            ax[i] = 24.0 * fxa;
            ay[i] = 24.0 * fya;
            az[i] = 24.0 * fza;
            pot_t += ua;
            if (tem_b)
            {
                ax[ib] = 24.0 * fxb;
                ay[ib] = 24.0 * fyb;
                az[ib] = 24.0 * fzb;
                pot_t += ub;
            }
        }

        const int t = omp_get_thread_num();
        pot_parcial[t][0] = pot_t;
        if (t == 0)
            nthreads = omp_get_num_threads();
    } /* fim do parallel = barreira: todas as parciais já estão escritas */

    for (int t = 0; t < nthreads; t++)
        pot += pot_parcial[t][0];

    /* soma sobre todos os pares i != j = o "2 * Pot" do Potential original */
    PE_atual = 4.0 * epsilon * pot;
}

double Potential(void)
{
    return PE_atual;
}
