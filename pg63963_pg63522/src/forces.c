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

/* Energia potencial das posições do último computeAccelerations(). Calcula-se no
   mesmo ciclo das forças (mesmos pares, mesmo 1/r2) e o Potential() só a devolve:
   no ciclo principal as posições não mudam entre computeAccelerations() (dentro do
   VelocityVerlet) e Potential(). */
static double PE_atual = 0.0;

/* Tamanho do bloco de j: os temporários (2 x BLK doubles = 8 KB) ficam na L1 (64 KB). */
#ifndef BLK
#define BLK 512
#endif

void computeAccelerations(void)
{
    double pot = 0.0;

#pragma omp parallel reduction(+ : pot)
    {
        /* temporários privados de cada thread (na stack): sem partilha, sem data races */
        double r2v[BLK], inv2v[BLK];

#pragma omp for schedule(static)
        for (int i = 0; i < N; i++)
        {
            const double xi = rx[i];
            const double yi = ry[i];
            const double zi = rz[i];
            double fx = 0.0, fy = 0.0, fz = 0.0, ui = 0.0;

            /* cadeia longa de dependências partida em 3 ciclos curtos por bloco de j:
               o CPU consegue ter muitas iterações independentes em execução (esconde a latência) */
            for (int j0 = 0; j0 < N; j0 += BLK)
            {
                const int n = (N - j0 < BLK) ? N - j0 : BLK;

                /* fase 1: distância ao quadrado */
                for (int k = 0; k < n; k++)
                {
                    const double dx = xi - rx[j0 + k];
                    const double dy = yi - ry[j0 + k];
                    const double dz = zi - rz[j0 + k];
                    r2v[k] = dx * dx + dy * dy + dz * dz;
                }

                /* fase 2: 1/r2 aproximado + 1 iteração de Newton; j == i -> 0 */
                for (int k = 0; k < n; k++)
                {
                    const double r2 = r2v[k];
                    const double inv0 = 1.0 / r2;
                    inv2v[k] = (r2 > 0.0) ? inv0 * (2.0 - r2 * inv0) : 0.0;
                }

                /* fase 3: potências em árvore (sigma = epsilon = 1), o 24 fica para o fim */
                for (int k = 0; k < n; k++)
                {
                    const double dx = xi - rx[j0 + k];
                    const double dy = yi - ry[j0 + k];
                    const double dz = zi - rz[j0 + k];
                    const double inv2 = inv2v[k];

                    const double dois_inv2 = inv2 + inv2;
                    const double inv4 = inv2 * inv2;
                    const double inv6 = inv4 * inv2;
                    const double inv8 = inv4 * inv4;
                    const double s = dois_inv2 * inv4 - 1.0;
                    const double f = inv8 * s;

                    ui += inv6 * (inv6 - 1.0);
                    fx += dx * f;
                    fy += dy * f;
                    fz += dz * f;
                }
            }

            ax[i] = 24.0 * fx;
            ay[i] = 24.0 * fy;
            az[i] = 24.0 * fz;
            pot += ui;
        }
    }
    PE_atual = 4.0 * epsilon * pot;
}

double Potential(void)
{
    return PE_atual;
}
