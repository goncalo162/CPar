/*
 MD.c - Lennard-Jones molecular dynamics (noble gases)
 OpenMP. Versão otimizada SEM cutoff e SEM cell lists, para manter
 resultados identicos (12+ algarismos significativos) a referencia:

   - Todos os pares O(N^2) calculados, na mesma ordem e com as
     mesmas operacoes da versao de referencia.
   - Layout SoA: r[3][MAXPART], v, a -> acessos contiguos sobre j,
     carregamentos SIMD eficientes, arrays alinhados a 64 bytes.
   - Energia potencial fundida no kernel de forcas (PotAcc):
     elimina um passe O(N^2) inteiro por passo.
   - Teste r2 > 0 em vez de i == j (mesmos bits, vetoriza melhor).
   - KE e <v^2> calculados num unico passe fundido (mesma ordem
     de soma -> mesmos bits).
   - Inicializacao das posicoes paralelizada (first-touch NUMA).

 Compilar:
   gcc -O3 -march=native -fopenmp MD.c -o MD -lm
 Execucao (afinidade ajuda em maquinas multi-socket):
   OMP_PROC_BIND=close OMP_PLACES=cores ./MD
*/

#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <stdbool.h>
#include <omp.h>

#define MAXPART 5001
#define DIM 3

int N;

/* Parametros reduzidos do potencial */
double sigma = 1.0, epsilon = 1.0, m = 1.0, kB = 1.0;

/* Constantes fisicas / conversoes */
double NA = 6.022140857e23;
double kBSI = 1.38064852e-23;

double L;        /* lado da caixa */
double Tinit;    /* temperatura inicial reduzida */

/* Layout SoA: r[k][i] = coordenada k da particula i.
   Alinhado a 64 bytes para carregamentos SIMD. */
static double r[DIM][MAXPART] __attribute__((aligned(64)));
static double v[DIM][MAXPART] __attribute__((aligned(64)));
static double a[DIM][MAXPART] __attribute__((aligned(64)));

char atype[10];

void initialize(void);
double VelocityVerlet(double dt, int iter, FILE *fp);
void computeAccelerations(void);
double gaussdist(void);
void initializeVelocities(void);
double Potential(void);
void Thermo(double *mvs, double *ke);
double MeanSquaredVelocity(void);
double Kinetic(void);

static double PotAcc = 0.0;   /* energia potencial do ultimo passo */


/* =========================================================
   MAIN
   ========================================================= */

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


    /* Select gas */

    printf("\n  WHICH NOBLE GAS WOULD YOU LIKE TO SIMULATE? (DEFAULT IS ARGON)\n");
    printf("  Type He, Ne, Ar, Kr, or Xe:\n");

    if (scanf("%9s", atype) != 1)
        return EXIT_FAILURE;


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
        PressFac = 59935428.402750031;
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


    /* Density */

    printf("\n  ENTER THE NUMBER DENSITY IN moles/m^3:\n");

    if (scanf("%lf", &rho) != 1 || rho <= 0.0) {
        fprintf(stderr, "Density must be positive.\n");
        return EXIT_FAILURE;
    }

    N = 5000;

    Vol = N / (rho * NA);
    Vol /= VolFac;


    if (N >= MAXPART) {
        fprintf(stderr, "Maximum number of particles is %d\n",
                MAXPART - 1);
        return EXIT_FAILURE;
    }

    if (Vol < N) {
        fprintf(stderr, "Density too high: available volume is too small.\n");
        return EXIT_FAILURE;
    }

    L = cbrt(Vol);


    /* Open output files */

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


    /* Time parameters */

    int NumTime;

    if (strcmp(atype, "He") == 0) {

        dt = 0.2e-14 / timefac;
        NumTime = 50000;

    } else {

        dt = 0.5e-14 / timefac;
        NumTime = 200;
    }


    /* Initialization */

    initialize();

    computeAccelerations();

    fprintf(tfp, "%d\n", N);

    Pavg = 0.0;
    Tavg = 0.0;

    int tenp = NumTime / 10;

    fprintf(ofp,
        "time (s) T(t) (K) P(t) (Pa) "
        "Kinetic En. (n.u.) Potential En. (n.u.) Total En. (n.u.)\n");

    printf("PERCENTAGE OF CALCULATION COMPLETE:\n[");


    /* Main simulation loop */

    for (i = 0; i < NumTime + 1; i++) {

        if (tenp > 0 && i > 0 && i % tenp == 0) {

            int percent = (int)(100.0 * i / NumTime);

            if (percent > 100)
                percent = 100;

            printf(" %d%% |", percent);
            fflush(stdout);
        }


        Press = VelocityVerlet(dt, i + 1, tfp) * PressFac;

        /* KE e <v^2> num unico passe (mesma ordem de soma que
           as duas funcoes separadas da referencia) */
        Thermo(&mvs, &KE);

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


        fprintf(ofp,
            "%8.4e %20.8f %20.8f %20.8f %20.8f %20.8f\n",
            i * dt * timefac,
            Temp,
            Press,
            KE,
            PE,
            KE + PE);
    }


    /* Average values */

    Pavg /= NumTime;
    Tavg /= NumTime;

    Z = Pavg * (Vol * VolFac) / (N * kBSI * Tavg);

    gc = NA * Pavg * (Vol * VolFac) / (N * Tavg);


    fprintf(afp,
        "Total Time (s) T (K) P (Pa) PV/nT (J/(mol K)) Z V (m^3) N\n");

    fprintf(afp,
        "%8.4e %15.5f %15.5f %10.5f %10.5f %10.5e %d\n",
        (NumTime + 1) * dt * timefac,
        Tavg,
        Pavg,
        gc,
        Z,
        Vol * VolFac,
        N);


    printf("\nSimulation complete.\n");

    printf("Trajectory: %s\n", tfn);
    printf("Output: %s\n", ofn);
    printf("Averages: %s\n", afn);

    printf("Average temperature (K): %.5f\n", Tavg);
    printf("Average pressure (Pa): %.5f\n", Pavg);

    printf("PV/nT (J mol^-1 K^-1): %.5f\n", gc);
    printf("Compressibility: %.5f\n", Z);

    printf("Percent error in gas constant: %.5f%%\n",
        100.0 * fabs(gc - 8.3144598) / 8.3144598);


    fclose(tfp);
    fclose(ofp);
    fclose(afp);

    return EXIT_SUCCESS;
}


/* =========================================================
   INITIALIZE POSITIONS
   Paralelizado: first-touch NUMA (as paginas ficam distribuidas
   pelas threads que as vao usar no kernel O(N^2)).
   ========================================================= */

void initialize(void)
{
    const int n = (int)ceil(cbrt((double)N));

    const double pos = L / n;

    /* mesma expressao (i+0.5)*pos da versao original: p percorre
       o mesmo mapeamento (i,j,k) da tripla original */
    #pragma omp parallel for schedule(static)
    for (int p = 0; p < N; p++) {

        const int i = p / (n * n);
        const int j = (p / n) % n;
        const int k = p % n;

        r[0][p] = (i + 0.5) * pos;
        r[1][p] = (j + 0.5) * pos;
        r[2][p] = (k + 0.5) * pos;
    }

    initializeVelocities();
}


/* =========================================================
   THERMO: <v^2> e energia cinetica num unico passe.
   As somas por thread percorrem os mesmos intervalos de i com
   a mesma ordem -> resultados bitwise identicos as versoes
   separadas (para um numero fixo de threads).
   ========================================================= */

void Thermo(double *mvs, double *ke)
{
    double sum = 0.0;
    double kin = 0.0;

    #pragma omp parallel for reduction(+:sum,kin) schedule(static)
    for (int i = 0; i < N; i++) {

        const double vx = v[0][i];
        const double vy = v[1][i];
        const double vz = v[2][i];

        const double s = vx * vx + vy * vy + vz * vz;

        sum += s;
        kin += 0.5 * m * s;
    }

    *mvs = sum / N;
    *ke  = kin;
}

double MeanSquaredVelocity(void)
{
    double mvs, ke;
    Thermo(&mvs, &ke);
    return mvs;
}

double Kinetic(void)
{
    double mvs, ke;
    Thermo(&mvs, &ke);
    return ke;
}


/* =========================================================
   POTENTIAL ENERGY (fundida no kernel de forcas)
   ========================================================= */

double Potential(void)
{
    /* Valor do ultimo computeAccelerations(): as posicoes nao
       mudam entre a atualizacao das aceleracoes e esta chamada. */
    return PotAcc;
}


/* =========================================================
   COMPUTE ACCELERATIONS  (todos os pares, ordem identica)
   ========================================================= */

void computeAccelerations(void)
{
    double Pot = 0.0;

    const double sig2   = sigma * sigma;
    const double factor = 4.0 * epsilon;

    #pragma omp parallel for schedule(static) reduction(+:Pot)
    for (int i = 0; i < N; i++) {

        const double xi = r[0][i];
        const double yi = r[1][i];
        const double zi = r[2][i];

        double fx = 0.0;
        double fy = 0.0;
        double fz = 0.0;
        double pe = 0.0;

        /* loop contiguo sobre j: carregamentos SIMD com SoA */
        for (int j = 0; j < N; j++) {

            const double dx = xi - r[0][j];
            const double dy = yi - r[1][j];
            const double dz = zi - r[2][j];

            const double r2 = dx*dx + dy*dy + dz*dz;

            /* r2 == 0 apenas no auto-par (i == j); mesmo resultado
               que o teste i == j da referencia, mas vetorizavel */
            const double inv2 = (r2 > 0.0) ? 1.0 / r2 : 0.0;

            const double inv4  = inv2 * inv2;
            const double inv8  = inv4 * inv4;
            const double inv14 = inv8 * inv4 * inv2;

            const double f = 24.0 * epsilon * (2.0 * inv14 - inv8);

            fx += dx * f;
            fy += dy * f;
            fz += dz * f;

            const double q2 = sig2 * inv2;
            const double q6 = q2 * q2 * q2;

            pe += q6 * q6 - q6;
        }

        a[0][i] = fx / m;
        a[1][i] = fy / m;
        a[2][i] = fz / m;

        /* mesma forma da versao de referencia: Pot += factor * pe */
        Pot += factor * pe;
    }

    PotAcc = Pot;
}


/* =========================================================
   VELOCITY VERLET
   ========================================================= */

double VelocityVerlet(double dt, int iter, FILE *fp)
{
    (void)iter;
    (void)fp;

    double psum = 0.0;

    const double half_dt  = 0.5 * dt;
    const double half_dt2 = 0.5 * dt * dt;


    /* First half of the timestep */

    #pragma omp parallel for schedule(static)
    for (int i = 0; i < N; i++) {

        for (int k = 0; k < DIM; k++) {

            r[k][i] += v[k][i] * dt
                     + a[k][i] * half_dt2;

            v[k][i] += a[k][i] * half_dt;
        }
    }


    /* Recalculate accelerations */

    computeAccelerations();


    /* Second half of the timestep and wall pressure */

    #pragma omp parallel for schedule(static) reduction(+:psum)
    for (int i = 0; i < N; i++) {

        for (int k = 0; k < DIM; k++) {

            v[k][i] += a[k][i] * half_dt;

            if (r[k][i] < 0.0 || r[k][i] >= L) {

                v[k][i] = -v[k][i];

                psum += 2.0 * m * fabs(v[k][i]) / dt;
            }
        }
    }

    return psum / (6.0 * L * L);
}


/* =========================================================
   INITIALIZE VELOCITIES
   ========================================================= */

void initializeVelocities(void)
{
    double vCMx = 0.0;
    double vCMy = 0.0;
    double vCMz = 0.0;

    double vSqdSum = 0.0;
    double lambda;


    /* Generate random velocities */

    for (int i = 0; i < N; i++) {

        v[0][i] = gaussdist();
        v[1][i] = gaussdist();
        v[2][i] = gaussdist();

        vCMx += m * v[0][i];
        vCMy += m * v[1][i];
        vCMz += m * v[2][i];
    }


    /* Calculate center of mass velocity */

    vCMx /= N * m;
    vCMy /= N * m;
    vCMz /= N * m;


    /* Remove center of mass velocity */

    for (int i = 0; i < N; i++) {

        v[0][i] -= vCMx;
        v[1][i] -= vCMy;
        v[2][i] -= vCMz;

        vSqdSum += v[0][i] * v[0][i]
                 + v[1][i] * v[1][i]
                 + v[2][i] * v[2][i];
    }


    /* Scale velocities to initial temperature */

    lambda = sqrt(3.0 * (N - 1) * Tinit / vSqdSum);


    for (int i = 0; i < N; i++) {

        v[0][i] *= lambda;
        v[1][i] *= lambda;
        v[2][i] *= lambda;
    }
}


/* =========================================================
   GAUSSIAN DISTRIBUTION
   ========================================================= */

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