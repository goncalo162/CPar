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
    if (scanf("%999s", prefix) != 1) return EXIT_FAILURE;

    snprintf(tfn, sizeof tfn, "%s_traj.xyz", prefix);
    snprintf(ofn, sizeof ofn, "%s_output.txt", prefix);
    snprintf(afn, sizeof afn, "%s_average.txt", prefix);

    printf("\n  WHICH NOBLE GAS WOULD YOU LIKE TO SIMULATE? (DEFAULT IS ARGON)\n");
    printf("  Type He, Ne, Ar, Kr, or Xe:\n");
    if (scanf("%9s", atype) != 1) return EXIT_FAILURE;

    if (strcmp(atype, "He") == 0) {
        VolFac = 1.8399744000000005e-29;
        PressFac = 8152287.336171632;
        TempFac = 10.864459551225972;
        timefac = 1.7572698825166272e-12;
    } else if (strcmp(atype, "Ne") == 0) {
        VolFac = 2.0570823999999997e-29;
        PressFac = 27223022.27659913;
        TempFac = 40.560648991243625;
        timefac = 2.1192341945685407e-12;
    } else if (strcmp(atype, "Ar") == 0) {
        VolFac = 3.7949992920124995e-29;
        PressFac = 51695201.06691862;
        TempFac = 142.095;
        timefac = 2.09618e-12;
    } else if (strcmp(atype, "Kr") == 0) {
        VolFac = 4.5882712000000004e-29;
        PressFac = 59935428.40275003;
        TempFac = 199.1817584391428;
        timefac = 8.051563913585078e-13;
    } else if (strcmp(atype, "Xe") == 0) {
        VolFac = 5.4872e-29;
        PressFac = 70527773.72794868;
        TempFac = 280.30305642163006;
        timefac = 9.018957925790732e-13;
    } else {
        strcpy(atype, "Ar");
        VolFac = 3.7949992920124995e-29;
        PressFac = 51695201.06691862;
        TempFac = 142.095;
        timefac = 2.09618e-12;
    }

    printf("\n  YOU ARE SIMULATING %s GAS!\n", atype);
    printf("\n  ENTER THE INITIAL TEMPERATURE IN KELVIN:\n");
    if (scanf("%lf", &Tinit) != 1 || Tinit < 0.0) {
        fprintf(stderr, "Temperature must be a non-negative number.\n");
        return EXIT_FAILURE;
    }
    Tinit /= TempFac;

    printf("\n  ENTER THE NUMBER DENSITY IN moles/m^3:\n");
    if (scanf("%lf", &rho) != 1 || rho <= 0.0) {
        fprintf(stderr, "Density must be positive.\n");
        return EXIT_FAILURE;
    }

    N = 5000;
    Vol = N / (rho * NA);
    Vol /= VolFac;

    if (N >= MAXPART) {
        fprintf(stderr, "Maximum number of particles is %d\n", MAXPART - 1);
        return EXIT_FAILURE;
    }
    if (Vol < N) {
        fprintf(stderr, "Density too high: available volume is too small.\n");
        return EXIT_FAILURE;
    }

    L = cbrt(Vol);

    tfp = fopen(tfn, "w");
    ofp = fopen(ofn, "w");
    afp = fopen(afn, "w");
    if (!tfp || !ofp || !afp) {
        perror("Could not open output file");
        if (tfp) fclose(tfp);
        if (ofp) fclose(ofp);
        if (afp) fclose(afp);
        return EXIT_FAILURE;
    }

    int NumTime;
    if (strcmp(atype, "He") == 0) {
        dt = 0.2e-14 / timefac;
        NumTime = 50000;
    } else {
        dt = 0.5e-14 / timefac;
        NumTime = 200;
    }

    initialize();
    computeAccelerations();

    fprintf(tfp, "%d\n", N);
    Pavg = 0.0;
    Tavg = 0.0;

    int tenp = NumTime / 10;
    fprintf(ofp, "time (s) T(t) (K) P(t) (Pa) Kinetic En. (n.u.) Potential En. (n.u.) Total En. (n.u.)\n");
    printf("PERCENTAGE OF CALCULATION COMPLETE:\n[");

    for (i = 0; i < NumTime + 1; i++) {
        if (tenp > 0 && i > 0 && i % tenp == 0) {
            int percent = (int)(100.0 * i / NumTime);
            if (percent > 100) percent = 100;
            printf(" %d%% |", percent);
            fflush(stdout);
        }

        Press = VelocityVerlet(dt, i + 1, tfp) * PressFac;
        mvs = MeanSquaredVelocity();
        KE = Kinetic();
        PE = Potential();

        Temp = m * mvs / (3.0 * kB) * TempFac;
        if (Temp != 0.0) {
            gc = NA * Press * (Vol * VolFac) / (N * Temp);
            Z = Press * (Vol * VolFac) / (N * kBSI * Temp);
        } else {
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

    printf("\nSimulation complete.\nTrajectory: %s\nOutput: %s\nAverages: %s\n",
           tfn, ofn, afn);
    printf("Average temperature (K): %.5f\nAverage pressure (Pa): %.5f\n",
           Tavg, Pavg);
    printf("PV/nT (J mol^-1 K^-1): %.5f\nCompressibility: %.5f\n",
           gc, Z);
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

    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            for (int k = 0; k < n; k++) {
                if (p < N) {
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

    #pragma omp parallel for reduction(+:sx,sy,sz) schedule(static)
    for (int i = 0; i < N; i++) {
        sx += vx[i] * vx[i];
        sy += vy[i] * vy[i];
        sz += vz[i] * vz[i];
    }
    return (sx + sy + sz) / N;
}


double Kinetic(void)
{
    double kin = 0.0;

    #pragma omp parallel for reduction(+:kin) schedule(static)
    for (int i = 0; i < N; i++) {
        kin += 0.5 * m * (vx[i]*vx[i] + vy[i]*vy[i] + vz[i]*vz[i]);
    }
    return kin;
}

double Potential(void)
{
    double Pot = 0.0;
    const double sig2 = sigma * sigma;
    const double factor = 4.0 * epsilon;

    #pragma omp parallel for reduction(+:Pot) schedule(static)
    for (int i = 0; i < N - 1; i++) {
        const double xi = rx[i], yi = ry[i], zi = rz[i];
        double sum_i = 0.0;

        #pragma omp simd reduction(+:sum_i)
        for (int j = i + 1; j < N; j++) {
            const double dx = xi - rx[j];
            const double dy = yi - ry[j];
            const double dz = zi - rz[j];
            const double r2 = dx*dx + dy*dy + dz*dz;
            const double q2 = sig2 / r2;
            const double q6 = q2*q2*q2;
            sum_i += factor * (q6*q6 - q6);
        }
        Pot += sum_i;
    }
    return 2.0 * Pot; //O original conta cada par duas vezes, multiplicar para comparar
}


void computeAccelerations(void)
{
    #pragma omp parallel for schedule(static)
    for (int i = 0; i < N; i++) {
        const double xi = rx[i];
        const double yi = ry[i];
        const double zi = rz[i];
        double fx = 0.0, fy = 0.0, fz = 0.0;

        #pragma omp simd reduction(+:fx,fy,fz)
        for (int j = 0; j < N; j++) {
            const double dx = xi - rx[j];
            const double dy = yi - ry[j];
            const double dz = zi - rz[j];

            const double r2 = dx*dx + dy*dy + dz*dz;
            /* seleção sem ramo: evita divisão por zero em j == i */
            const double inv2 = (i == j) ? 0.0 : 1.0 / r2;
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


double VelocityVerlet(double dt, int iter, FILE *fp)
{
    (void)iter;
    (void)fp;

    double psum = 0.0;
    const double half_dt = 0.5 * dt;
    const double half_dt2 = 0.5 * dt * dt;

    /* Primeira metade do passo: posições + primeira metade das velocidades. */
    #pragma omp parallel for schedule(static)
    for (int i = 0; i < N; i++) {
        rx[i] += vx[i] * dt + ax[i] * half_dt2;
        ry[i] += vy[i] * dt + ay[i] * half_dt2;
        rz[i] += vz[i] * dt + az[i] * half_dt2;

        vx[i] += ax[i] * half_dt;
        vy[i] += ay[i] * half_dt;
        vz[i] += az[i] * half_dt;
    }

    computeAccelerations();

    /* Segunda metade do passo + pressão nas paredes. */
    #pragma omp parallel for schedule(static) reduction(+:psum)
    for (int i = 0; i < N; i++) {
        vx[i] += ax[i] * half_dt;
        vy[i] += ay[i] * half_dt;
        vz[i] += az[i] * half_dt;

        if (rx[i] < 0.0) {
            vx[i] = -vx[i];
            psum += 2.0 * m * fabs(vx[i]) / dt;
        } else if (rx[i] >= L) {
            vx[i] = -vx[i];
            psum += 2.0 * m * fabs(vx[i]) / dt;
        }

        if (ry[i] < 0.0) {
            vy[i] = -vy[i];
            psum += 2.0 * m * fabs(vy[i]) / dt;
        } else if (ry[i] >= L) {
            vy[i] = -vy[i];
            psum += 2.0 * m * fabs(vy[i]) / dt;
        }

        if (rz[i] < 0.0) {
            vz[i] = -vz[i];
            psum += 2.0 * m * fabs(vz[i]) / dt;
        } else if (rz[i] >= L) {
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

    for (int i = 0; i < N; i++) {
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

    for (int i = 0; i < N; i++) {
        vx[i] -= vCMx;
        vy[i] -= vCMy;
        vz[i] -= vCMz;
        vSqdSum += vx[i]*vx[i] + vy[i]*vy[i] + vz[i]*vz[i];
    }

    lambda = sqrt(3.0 * (N - 1) * Tinit / vSqdSum);

    for (int i = 0; i < N; i++) {
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

    if (!available) {
        do {
            v1 = 2.0 * rand() / (double)RAND_MAX - 1.0;
            v2 = 2.0 * rand() / (double)RAND_MAX - 1.0;
            rsq = v1*v1 + v2*v2;
        } while (rsq >= 1.0 || rsq == 0.0);

        fac = sqrt(-2.0 * log(rsq) / rsq);
        gset = v1 * fac;
        available = true;
        return v2 * fac;
    }

    available = false;
    return gset;
}