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

void computeAccelerations(void)
{
#pragma omp parallel for schedule(static)
    for (int i = 0; i < N; i++)
    {
        const double xi = rx[i];
        const double yi = ry[i];
        const double zi = rz[i];
        double fx = 0.0, fy = 0.0, fz = 0.0;

        for (int j = 0; j < N; j++)
        {
            const double dx = xi - rx[j];
            const double dy = yi - ry[j];
            const double dz = zi - rz[j];

            const double r2 = dx * dx + dy * dy + dz * dz;
            const double inv0 = 1.0 / r2;
            const double inv2 = (r2 > 0.0) ? inv0 * (2.0 - r2 * inv0) : 0.0;
            const double inv4 = inv2 * inv2;
            const double inv8 = inv4 * inv4;
            const double inv14 = inv8 * inv4 * inv2;

            const double f = 24.0 * (2.0 * inv14 - inv8);

            fx += dx * f;
            fy += dy * f;
            fz += dz * f;
        }

        ax[i] = fx;
        ay[i] = fy;
        az[i] = fz;
    }
}

double Potential(void)
{
    double Pot = 0.0;
    const double sig2 = sigma * sigma;
    const double factor = 4.0 * epsilon;

#pragma omp parallel for reduction(+ : Pot) schedule(dynamic, 20)
    for (int i = 0; i < N - 1; i++)
    {
        const double xi = rx[i], yi = ry[i], zi = rz[i];
        double sum_i = 0.0;

        for (int j = i + 1; j < N; j++)
        {
            const double dx = xi - rx[j];
            const double dy = yi - ry[j];
            const double dz = zi - rz[j];
            const double r2 = dx * dx + dy * dy + dz * dz;
            /* 1/r2 aproximado (-mlow-precision-div) + 1 iteração de Newton
               para recuperar a precisão total do double */
            const double inv0 = 1.0 / r2;
            const double q2 = sig2 * inv0 * (2.0 - r2 * inv0);
            const double q6 = q2 * q2 * q2;
            sum_i += factor * (q6 * q6 - q6);
        }
        Pot += sum_i;
    }
    return 2.0 * Pot; // O original conta cada par duas vezes, multiplicar para comparar
}
