/*
    MD.c - Lennard-Jones molecular dynamics
    OpenMP + SIMD optimized version using SoA positions.
*/
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <stdbool.h>
#include <omp.h>
#include <arm_sve.h> /* SIMD nativo do A64FX (SVE) */

#define MAXPART 5001

int N;
double sigma = 1.0, epsilon = 1.0, m = 1.0, kB = 1.0;
double NA = 6.022140857e23;
double kBSI = 1.38064852e-23;
double L, Tinit;

double rx[MAXPART], ry[MAXPART], rz[MAXPART];
double vx[MAXPART], vy[MAXPART], vz[MAXPART];
double ax[MAXPART], ay[MAXPART], az[MAXPART];

char atype[10];

void initialize(void);
double VelocityVerlet(double dt, int iter, FILE *fp);
void computeAccelerations(void);
double gaussdist(void);
void initializeVelocities(void);
double Potential(void);
double MeanSquaredVelocity(void);
double Kinetic(void);
#if defined(MD_SVE_CHECK)
void sveSelfCheck(void);
#endif

int main(void)
{
    int i;
    double dt, Vol, Temp, Press, Pavg, Tavg, rho;
    double VolFac, TempFac, PressFac, timefac;
    double KE, PE, mvs, gc, Z;
    char prefix[1000], tfn[1100], ofn[1100], afn[1100];
    FILE *tfp, *ofp, *afp;

    printf("\n  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
    printf("                  WELCOME TO WILLY P CHEM MD!\n");
    printf("  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
    printf("\n  ENTER A TITLE FOR YOUR CALCULATION!\n");
    if (scanf("%999s", prefix) != 1)
        return EXIT_FAILURE;

    snprintf(tfn, sizeof tfn, "%s_traj.xyz", prefix);
    snprintf(ofn, sizeof ofn, "%s_output.txt", prefix);
    snprintf(afn, sizeof afn, "%s_average.txt", prefix);

    printf("\n  WHICH NOBLE GAS WOULD YOU LIKE TO SIMULATE? (DEFAULT IS ARGON)\n");
    printf("  Type He, Ne, Ar, Kr, or Xe:\n");
    if (scanf("%9s", atype) != 1)
        return EXIT_FAILURE;

    if (strcmp(atype, "He") == 0)
    {
        VolFac = 1.8399744000000005e-29;
        PressFac = 8152287.336171632;
        TempFac = 10.864459551225972;
        timefac = 1.7572698825166272e-12;
    }
    else if (strcmp(atype, "Ne") == 0)
    {
        VolFac = 2.0570823999999997e-29;
        PressFac = 27223022.27659913;
        TempFac = 40.560648991243625;
        timefac = 2.1192341945685407e-12;
    }
    else if (strcmp(atype, "Ar") == 0)
    {
        VolFac = 3.7949992920124995e-29;
        PressFac = 51695201.06691862;
        TempFac = 142.095;
        timefac = 2.09618e-12;
    }
    else if (strcmp(atype, "Kr") == 0)
    {
        VolFac = 4.5882712000000004e-29;
        PressFac = 59935428.40275003;
        TempFac = 199.1817584391428;
        timefac = 8.051563913585078e-13;
    }
    else if (strcmp(atype, "Xe") == 0)
    {
        VolFac = 5.4872e-29;
        PressFac = 70527773.72794868;
        TempFac = 280.30305642163006;
        timefac = 9.018957925790732e-13;
    }
    else
    {
        strcpy(atype, "Ar");
        VolFac = 3.7949992920124995e-29;
        PressFac = 51695201.06691862;
        TempFac = 142.095;
        timefac = 2.09618e-12;
    }

    printf("\n  YOU ARE SIMULATING %s GAS!\n", atype);
    printf("\n  ENTER THE INITIAL TEMPERATURE IN KELVIN:\n");
    if (scanf("%lf", &Tinit) != 1 || Tinit < 0.0)
    {
        fprintf(stderr, "Temperature must be a non-negative number.\n");
        return EXIT_FAILURE;
    }
    Tinit /= TempFac;

    printf("\n  ENTER THE NUMBER DENSITY IN moles/m^3:\n");
    if (scanf("%lf", &rho) != 1 || rho <= 0.0)
    {
        fprintf(stderr, "Density must be positive.\n");
        return EXIT_FAILURE;
    }

    N = 5000;
    Vol = N / (rho * NA);
    Vol /= VolFac;

    if (N >= MAXPART)
    {
        fprintf(stderr, "Maximum number of particles is %d\n", MAXPART - 1);
        return EXIT_FAILURE;
    }
    if (Vol < N)
    {
        fprintf(stderr, "Density too high: available volume is too small.\n");
        return EXIT_FAILURE;
    }

    L = cbrt(Vol);

    tfp = fopen(tfn, "w");
    ofp = fopen(ofn, "w");
    afp = fopen(afn, "w");
    if (!tfp || !ofp || !afp)
    {
        perror("Could not open output file");
        if (tfp)
            fclose(tfp);
        if (ofp)
            fclose(ofp);
        if (afp)
            fclose(afp);
        return EXIT_FAILURE;
    }

    int NumTime;
    if (strcmp(atype, "He") == 0)
    {
        dt = 0.2e-14 / timefac;
        NumTime = 50000;
    }
    else
    {
        dt = 0.5e-14 / timefac;
        NumTime = 200;
    }
    // avaliar estes dois inits
    initialize();
    computeAccelerations();
#if defined(MD_SVE_CHECK)
    sveSelfCheck();
#endif

    fprintf(tfp, "%d\n", N);
    Pavg = 0.0;
    Tavg = 0.0;

    int tenp = NumTime / 10;
    fprintf(ofp, "time (s) T(t) (K) P(t) (Pa) Kinetic En. (n.u.) Potential En. (n.u.) Total En. (n.u.)\n");
    printf("PERCENTAGE OF CALCULATION COMPLETE:\n[");

    // Aqui entra no loop princiapal
    for (i = 0; i < NumTime + 1; i++)
    {
        if (tenp > 0 && i > 0 && i % tenp == 0)
        {
            int percent = (int)(100.0 * i / NumTime);
            if (percent > 100)
                percent = 100;
            printf(" %d%% |", percent);
            fflush(stdout);
        }

        Press = VelocityVerlet(dt, i + 1, tfp) * PressFac;
        mvs = MeanSquaredVelocity();
        KE = Kinetic();
        PE = Potential();

        Temp = m * mvs / (3.0 * kB) * TempFac;
        if (Temp != 0.0)
        {
            gc = NA * Press * (Vol * VolFac) / (N * Temp);
            Z = Press * (Vol * VolFac) / (N * kBSI * Temp);
        }
        else
        {
            gc = 0.0;
            Z = 0.0;
        }

        Tavg += Temp;
        Pavg += Press;

        fprintf(ofp, "%8.4e %20.8f %20.8f %20.8f %20.8f %20.8f\n",
                i * dt * timefac, Temp, Press, KE, PE, KE + PE);
    }

    Pavg /= NumTime;
    Tavg /= NumTime;
    Z = Pavg * (Vol * VolFac) / (N * kBSI * Tavg);
    gc = NA * Pavg * (Vol * VolFac) / (N * Tavg);

    fprintf(afp, "Total Time (s) T (K) P (Pa) PV/nT (J/(mol K)) Z V (m^3) N\n");
    fprintf(afp, "%8.4e %15.5f %15.5f %10.5f %10.5f %10.5e %d\n",
            (NumTime + 1) * dt * timefac, Tavg, Pavg, gc, Z, Vol * VolFac, N);

    printf("\nSimulation complete.\nTrajectory: %s\nOutput: %s\nAverages: %s\n", tfn, ofn, afn);
    printf("Average temperature (K): %.5f\nAverage pressure (Pa): %.5f\n", Tavg, Pavg);
    printf("PV/nT (J mol^-1 K^-1): %.5f\nCompressibility: %.5f\n", gc, Z);
    printf("Percent error in gas constant: %.5f%%\n",
           100.0 * fabs(gc - 8.3144598) / 8.3144598);

    fclose(tfp);
    fclose(ofp);
    fclose(afp);
    return EXIT_SUCCESS;
}

void initialize(void)
{
    int n = (int)ceil(cbrt((double)N));
    double pos = L / n;
    int p = 0;

    for (int i = 0; i < n; i++)
    {
        for (int j = 0; j < n; j++)
        {
            for (int k = 0; k < n; k++)
            {
                if (p < N)
                {
                    rx[p] = (i + 0.5) * pos;
                    ry[p] = (j + 0.5) * pos;
                    rz[p] = (k + 0.5) * pos;
                }
                p++;
            }
        }
    }
    initializeVelocities();
}

double MeanSquaredVelocity(void)
{
    double sx = 0.0, sy = 0.0, sz = 0.0;

#pragma omp parallel for reduction(+ : sx, sy, sz) schedule(static 1)
    for (int i = 0; i < N; i++)
    {
        sx += vx[i] * vx[i];
        sy += vy[i] * vy[i];
        sz += vz[i] * vz[i];
    }
    return (sx + sy + sz) / N;
}

double Kinetic(void)
{
    double kin = 0.0;

#pragma omp parallel for reduction(+ : kin) schedule(static 1)
    for (int i = 0; i < N; i++)
    {
        kin += 0.5 * m * (vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i]);
    }
    return kin;
}

/* Linha i da soma de pares do potencial (loop vetorial SVE; o predicado
   whilelt trata o resto e zeroa as lanes inativas). */
static inline double potRow(int i, double sig2, double factor)
{
    const double xi = rx[i], yi = ry[i], zi = rz[i];

    const svfloat64_t xiv = svdup_f64(xi);
    const svfloat64_t yiv = svdup_f64(yi);
    const svfloat64_t ziv = svdup_f64(zi);
    const svfloat64_t s2v = svdup_f64(sig2);
    const svfloat64_t fv = svdup_f64(factor);
    svfloat64_t acc = svdup_f64(0.0);

    for (int j = i + 1; j < N; j += (int)svcntd())
    {
        const svbool_t pg = svwhilelt_b64((uint64_t)j, (uint64_t)N);

        const svfloat64_t dx = svsub_f64_z(pg, xiv, svld1_f64(pg, &rx[j]));
        const svfloat64_t dy = svsub_f64_z(pg, yiv, svld1_f64(pg, &ry[j]));
        const svfloat64_t dz = svsub_f64_z(pg, ziv, svld1_f64(pg, &rz[j]));

        const svfloat64_t r2 = svmla_f64_z(pg, dx, dx,
                                           svmla_f64_z(pg, dy, dy,
                                                       svmul_f64_z(pg, dz, dz)));

        const svfloat64_t q2 = svdiv_f64_z(pg, s2v, r2);
        const svfloat64_t q6 = svmul_f64_z(pg, svmul_f64_z(pg, q2, q2), q2);
        const svfloat64_t t = svsub_f64_z(pg, svmul_f64_z(pg, q6, q6), q6);

        acc = svmla_f64_m(pg, acc, t, fv);
    }
    return svaddv_f64(svptrue_b64(), acc);
}

double Potential(void)
{
    double Pot = 0.0;
    const double sig2 = sigma * sigma;
    const double factor = 4.0 * epsilon;

#pragma omp parallel for reduction(+ : Pot) schedule(static 1)
    for (int i = 0; i < N - 1; i++)
    {
        Pot += potRow(i, sig2, factor);
    }
    return 2.0 * Pot; // O original conta cada par duas vezes, multiplicar para comparar
}

/* Linha i da matriz N x N de acelerações (loop vetorial SVE). O elemento
   diagonal (j == i, com r2 == 0) é excluído pelo predicado pgd, sem ramos. */
static inline void computeAccelRow(int i)
{
    const double xi = rx[i];
    const double yi = ry[i];
    const double zi = rz[i];

    const svfloat64_t xiv = svdup_f64(xi);
    const svfloat64_t yiv = svdup_f64(yi);
    const svfloat64_t ziv = svdup_f64(zi);
    const svfloat64_t one = svdup_f64(1.0);
    const svfloat64_t c24 = svdup_f64(24.0);
    const svfloat64_t two = svdup_f64(2.0);
    svfloat64_t fx = svdup_f64(0.0);
    svfloat64_t fy = svdup_f64(0.0);
    svfloat64_t fz = svdup_f64(0.0);

    for (int j = 0; j < N; j += (int)svcntd())
    {
        const svbool_t pg = svwhilelt_b64((uint64_t)j, (uint64_t)N);
        /* lanes ativas E j != i (comparador em inteiros: o predicador é
           agnóstico do tipo de elemento) */
        const svbool_t pgd = svcmpne_n_s64(pg, svindex_s64((uint64_t)j, 1), i);

        const svfloat64_t dx = svsub_f64_z(pg, xiv, svld1_f64(pg, &rx[j]));
        const svfloat64_t dy = svsub_f64_z(pg, yiv, svld1_f64(pg, &ry[j]));
        const svfloat64_t dz = svsub_f64_z(pg, ziv, svld1_f64(pg, &rz[j]));

        const svfloat64_t r2 = svmla_f64_z(pg, dx, dx,
                                           svmla_f64_z(pg, dy, dy,
                                                       svmul_f64_z(pg, dz, dz)));

        const svfloat64_t inv2 = svdiv_f64_z(pgd, one, r2);
        const svfloat64_t inv4 = svmul_f64_z(pgd, inv2, inv2);
        const svfloat64_t inv8 = svmul_f64_z(pgd, inv4, inv4);
        const svfloat64_t inv14 = svmul_f64_z(pgd, svmul_f64_z(pgd, inv8, inv4), inv2);
        const svfloat64_t f = svsub_f64_z(pgd, svmul_f64_z(pgd, inv14, two), inv8);
        const svfloat64_t f24 = svmul_f64_z(pgd, f, c24);

        fx = svmla_f64_m(pgd, fx, dx, f24);
        fy = svmla_f64_m(pgd, fy, dy, f24);
        fz = svmla_f64_m(pgd, fz, dz, f24);
    }

    ax[i] = svaddv_f64(svptrue_b64(), fx);
    ay[i] = svaddv_f64(svptrue_b64(), fy);
    az[i] = svaddv_f64(svptrue_b64(), fz);
}

void computeAccelerations(void)
{
#pragma omp parallel for schedule(static 1)
    for (int i = 0; i < N; i++)
    {
        computeAccelRow(i);
    }
}

#if defined(MD_SVE_CHECK)
/* Auto-teste: imprime o comprimento vetorial SVE em runtime e compara os
   kernels SVE com o cálculo escalar no estado inicial (1 chamada, O(N^2)). */
void sveSelfCheck(void)
{
    fprintf(stderr, "[MD_SVE_CHECK] svcntd = %d doubles (SVE de %d bits)\n",
            (int)svcntd(), (int)(64 * svcntd()));

    /* Acelerações: linhas 0, 1, N/2 e N-1 */
    double maxerr = 0.0;
    const int samples[4] = {0, 1, N / 2, N - 1};
    for (int s = 0; s < 4; s++)
    {
        const int i = samples[s];
        double fx = 0.0, fy = 0.0, fz = 0.0;

        for (int j = 0; j < N; j++)
        {
            if (j == i)
                continue;
            const double dx = rx[i] - rx[j];
            const double dy = ry[i] - ry[j];
            const double dz = rz[i] - rz[j];
            const double r2 = dx * dx + dy * dy + dz * dz;
            const double inv2 = 1.0 / r2;
            const double inv4 = inv2 * inv2;
            const double inv8 = inv4 * inv4;
            const double inv14 = inv8 * inv4 * inv2;
            const double f = 24.0 * (2.0 * inv14 - inv8);
            fx += dx * f;
            fy += dy * f;
            fz += dz * f;
        }

        computeAccelRow(i);

        const double ex[3] = {ax[i], ay[i], az[i]};
        const double ref[3] = {fx, fy, fz};
        for (int c = 0; c < 3; c++)
            maxerr = fmax(maxerr,
                          fabs(ex[c] - ref[c]) / (fabs(ref[c]) + 1e-300));
    }
    fprintf(stderr, "[MD_SVE_CHECK] aceleracoes: desvio relativo max = %.3e %s\n",
            maxerr, maxerr < 1e-9 ? "(OK)" : "(FALHOU!)");

    /* Potencial completo (2x por causa do fator do Potential()) */
    double potRef = 0.0;
    for (int i = 0; i < N - 1; i++)
    {
        for (int j = i + 1; j < N; j++)
        {
            const double dx = rx[i] - rx[j];
            const double dy = ry[i] - ry[j];
            const double dz = rz[i] - rz[j];
            const double r2 = dx * dx + dy * dy + dz * dz;
            const double q2 = sigma * sigma / r2;
            const double q6 = q2 * q2 * q2;
            potRef += 4.0 * epsilon * (q6 * q6 - q6);
        }
    }
    const double potSve = Potential();
    const double perr = fabs(potSve - 2.0 * potRef) / (fabs(2.0 * potRef) + 1e-300);
    fprintf(stderr, "[MD_SVE_CHECK] potencial: ref = %.15g  sve = %.15g  desvio = %.3e %s\n",
            2.0 * potRef, potSve, perr, perr < 1e-9 ? "(OK)" : "(FALHOU!)");
}
#endif

double VelocityVerlet(double dt, int iter, FILE *fp)
{
    (void)iter;
    (void)fp;

    double psum = 0.0;
    const double half_dt = 0.5 * dt;
    const double half_dt2 = 0.5 * dt * dt;

/* Primeira metade do passo: posições + primeira metade das velocidades. */
#pragma omp parallel for schedule(static 1)
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
#pragma omp parallel for schedule(static 1) reduction(+ : psum)
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
    }

    return psum / (6.0 * L * L);
}

void initializeVelocities(void)
{
    double vCMx = 0.0, vCMy = 0.0, vCMz = 0.0;
    double vSqdSum = 0.0, lambda;

    for (int i = 0; i < N; i++)
    {
        vx[i] = gaussdist();
        vy[i] = gaussdist();
        vz[i] = gaussdist();
        vCMx += m * vx[i];
        vCMy += m * vy[i];
        vCMz += m * vz[i];
    }

    vCMx /= N * m;
    vCMy /= N * m;
    vCMz /= N * m;

    for (int i = 0; i < N; i++)
    {
        vx[i] -= vCMx;
        vy[i] -= vCMy;
        vz[i] -= vCMz;
        vSqdSum += vx[i] * vx[i] + vy[i] * vy[i] + vz[i] * vz[i];
    }

    lambda = sqrt(3.0 * (N - 1) * Tinit / vSqdSum);

    for (int i = 0; i < N; i++)
    {
        vx[i] *= lambda;
        vy[i] *= lambda;
        vz[i] *= lambda;
    }
}

double gaussdist(void)
{
    static bool available = false;
    static double gset;
    double fac, rsq, v1, v2;

    if (!available)
    {
        do
        {
            v1 = 2.0 * rand() / (double)RAND_MAX - 1.0;
            v2 = 2.0 * rand() / (double)RAND_MAX - 1.0;
            rsq = v1 * v1 + v2 * v2;
        } while (rsq >= 1.0 || rsq == 0.0);

        fac = sqrt(-2.0 * log(rsq) / rsq);
        gset = v1 * fac;
        available = true;
        return v2 * fac;
    }

    available = false;
    return gset;
}