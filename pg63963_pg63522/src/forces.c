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

void computeAccelerations(void)
{
    const double sig2 = sigma * sigma;
    double pot = 0.0;

#pragma omp parallel for schedule(static) reduction(+ : pot)
    for (int i = 0; i < N; i++)
    {
        const double xi = rx[i];
        const double yi = ry[i];
        const double zi = rz[i];
        double fx = 0.0, fy = 0.0, fz = 0.0, ui = 0.0;

        for (int j = 0; j < N; j++)
        {
            const double dx = xi - rx[j];
            const double dy = yi - ry[j];
            const double dz = zi - rz[j];

            const double r2 = dx * dx + dy * dy + dz * dz;
            /* 1/r2 aproximado (-mlow-precision-div) + 1 iteração de Newton
               para recuperar a precisão total do double;
               seleção sem ramo: evita divisão por zero em j == i */
            const double inv0 = 1.0 / r2;
            const double inv2 = (r2 > 0.0) ? inv0 * (2.0 - r2 * inv0) : 0.0;
            const double inv4 = inv2 * inv2;
            const double inv8 = inv4 * inv4;
            const double inv14 = inv8 * inv4 * inv2;

            const double f = 24.0 * (2.0 * inv14 - inv8);

            /* energia potencial do par (j == i: inv2 = 0 -> soma 0) */
            const double q2 = sig2 * inv2;
            const double q6 = q2 * q2 * q2;
            ui += q6 * q6 - q6;

            fx += dx * f;
            fy += dy * f;
            fz += dz * f;
        }

        ax[i] = fx;
        ay[i] = fy;
        az[i] = fz;
        pot += ui;
    }
    /* soma sobre todos os pares i != j = o "2 * Pot" do Potential original */
    PE_atual = 4.0 * epsilon * pot;
}

double Potential(void)
{
    return PE_atual;
}
