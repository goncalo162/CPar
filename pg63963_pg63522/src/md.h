/*
    md.h - estado partilhado entre MD.cpp e forces.c
*/
#ifndef MD_H
#define MD_H

#define MAXPART 5001

extern int N;
extern double sigma, epsilon, m, kB;
extern double NA, kBSI;
extern double L, Tinit;

extern double rx[MAXPART], ry[MAXPART], rz[MAXPART];
extern double vx[MAXPART], vy[MAXPART], vz[MAXPART];
extern double ax[MAXPART], ay[MAXPART], az[MAXPART];

/* kernels O(N^2), em forces.c (compilado com -mlow-precision-div) */
void computeAccelerations(void);
double Potential(void);

#endif
