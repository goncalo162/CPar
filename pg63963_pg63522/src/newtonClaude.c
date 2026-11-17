#include "md.h"
#include <omp.h>
#include <arm_sve.h>
/* Energia potencial das posições do último computeAccelerations(). */
static double PE_atual = 0.0;

/* Tamanho do bloco de j: os temporários (2 x BLK doubles = 8 KB) ficam na L1 (64 KB). */
#ifndef BLK
#define BLK 512
#endif

#define MAX_THREADS_F 192
static double pot_parcial[MAX_THREADS_F][32] __attribute__((aligned(256)));

/* 3.ª lei de Newton: forças parciais de cada thread (-f dos j).
   Cada thread limpa os seus arrays no início do passo. */
#define MAXPAD ((MAXPART + 31) & ~31) /* linhas de 256 B */
static struct
{
    double x[MAXPAD], y[MAXPAD], z[MAXPAD];
} fp[MAX_THREADS_F] __attribute__((aligned(256)));

void computeAccelerations(void)
{
    double pot = 0.0;
    int nthreads = 1;

#pragma omp parallel
    {
        double pot_t = 0.0; /* soma local desta thread */
        const int t = omp_get_thread_num();
        double *const gx = fp[t].x, *const gy = fp[t].y, *const gz = fp[t].z;
        for (int j = 0; j < N; j++)
        {
            gx[j] = 0.0;
            gy[j] = 0.0;
            gz[j] = 0.0;
        }

        struct
        {
            double r2a[BLK], r2b[BLK], inva[BLK], invb[BLK];
        } tmp __attribute__((aligned(16384)));
        double *const r2a = tmp.r2a, *const r2b = tmp.r2b;
        double *const inva = tmp.inva, *const invb = tmp.invb;

#pragma omp for schedule(dynamic, 6)
        for (int i = 0; i < N; i += 2)
        {
            const int tem_b = (i + 1 < N); /* N ímpar: a última iteração só tem i */
            const int ib = tem_b ? i + 1 : i;

            const double xa = rx[i], ya = ry[i], za = rz[i];
            const double xb = rx[ib], yb = ry[ib], zb = rz[ib];
            double fxa = 0.0, fya = 0.0, fza = 0.0, ua = 0.0;
            double fxb = 0.0, fyb = 0.0, fzb = 0.0, ub = 0.0;

            for (int j0 = i + 1; j0 < N; j0 += BLK) /* Newton: só j > i */
            {
                const int n = (N - j0 < BLK) ? N - j0 : BLK;

                /* fase 1 */
                for (int k = 0; k < n; k++)
                {
                    const double xj = rx[j0 + k], yj = ry[j0 + k], zj = rz[j0 + k];
                    const double dxa = xa - xj, dya = ya - yj, dza = za - zj;
                    const double dxb = xb - xj, dyb = yb - yj, dzb = zb - zj;
                    r2a[k] = dxa * dxa + dya * dya + dza * dza;
                    r2b[k] = dxb * dxb + dyb * dyb + dzb * dzb;
                }

                /* fase 2 */
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
                /* o 1.º j é i+1 = ib: para b é o próprio (r2 = 0) */
                if (j0 == i + 1)
                    invb[0] = 0.0;

                /* fase 3 */
                for (int k = 0; k < n; k++)
                {
                    const double xj = rx[j0 + k], yj = ry[j0 + k], zj = rz[j0 + k];

                    const double i2a = inva[k];
                    const double i4a = i2a * i2a, i6a = i4a * i2a, i8a = i4a * i4a;
                    const double fa = i8a * ((i2a + i2a) * i4a - 1.0);

                    const double i2b = invb[k];
                    const double i4b = i2b * i2b, i6b = i4b * i2b, i8b = i4b * i4b;
                    const double fb = i8b * ((i2b + i2b) * i4b - 1.0);

                    const double pxa = (xa - xj) * fa, pya = (ya - yj) * fa, pza = (za - zj) * fa;
                    const double pxb = (xb - xj) * fb, pyb = (yb - yj) * fb, pzb = (zb - zj) * fb;

                    ua += i6a * (i6a - 1.0);
                    ub += i6b * (i6b - 1.0);
                    fxa += pxa;
                    fxb += pxb;
                    fya += pya;
                    fyb += pyb;
                    fza += pza;
                    fzb += pzb;

                    /* -f para j (cada k escreve num j diferente) */
                    gx[j0 + k] -= pxa + pxb;
                    gy[j0 + k] -= pya + pyb;
                    gz[j0 + k] -= pza + pzb;
                }
            }

            gx[i] += fxa;
            gy[i] += fya;
            gz[i] += fza;
            pot_t += ua;
            if (tem_b)
            {
                gx[ib] += fxb;
                gy[ib] += fyb;
                gz[ib] += fzb;
                pot_t += ub;
            }
        } /* barreira implícita: todos os fp completos */

        pot_parcial[t][0] = pot_t;
        if (t == 0)
            nthreads = omp_get_num_threads();

        /* redução: a[j] = 24 * soma das threads */
        const int nt = omp_get_num_threads();
        const int B = (N + nt - 1) / nt; /* um bloco contínuo de j por thread */
#pragma omp for schedule(static)
        for (int j0 = 0; j0 < N; j0 += B)
        {
            const int j1 = (j0 + B < N) ? j0 + B : N;
            for (int j = j0; j < j1; j++)
            {
                ax[j] = fp[0].x[j];
                ay[j] = fp[0].y[j];
                az[j] = fp[0].z[j];
            }
            for (int s = 1; s < nt; s++)
                for (int j = j0; j < j1; j++)
                {
                    ax[j] += fp[s].x[j];
                    ay[j] += fp[s].y[j];
                    az[j] += fp[s].z[j];
                }
            for (int j = j0; j < j1; j++)
            {
                ax[j] *= 24.0;
                ay[j] *= 24.0;
                az[j] *= 24.0;
            }
        }
    } /* fim do parallel = barreira */

    for (int t = 0; t < nthreads; t++)
        pot += pot_parcial[t][0];

    /* Newton: cada par contado uma vez, 2 * 4 * eps * soma = o "2 * Pot" original */
    PE_atual = 8.0 * epsilon * pot;
}

double Potential(void)
{
    return PE_atual;
}
