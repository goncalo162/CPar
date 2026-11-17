# 📊 Tabela de Resultados - Todas as Otimizações

**Cluster:** Fujitsu A64FX (ln02.deucalion.macc.fccn.pt)  
**Data:** 17/11/2026  
**Configuração:** 48 threads, OMP_PROC_BIND=close, OMP_PLACES=cores  
**Input:** inputdata.txt (N=5000, Ar, T=298K)  
**Nota:** Resultados extraídos de `optimized/results/benchmark_*_20261117_*/`

---

## Tabela Comparativa Principal (48 threads)

| # | Otimização | Tipo | Tempo (s) | L1 Misses | L2 Refills | Ciclos (G) | Instruções (G) | IPC | CPI | Status |
|---|-------------|------|-----------|-----------|------------|------------|-----------------|-----|-----|--------|
| - | **aligned_256** | Baseline | 0.1746 | 287,653,832 | 5,299,883 | 14,274 | 19,420 | **1.360** | 0.735 | ✅ Ref. |
| - | **aligned_16KB** | Baseline | 0.1998 | 298,464,644 | 11,628,749 | 16,717 | 20,539 | 1.229 | 0.814 | ✅ Ref. |
| 1 | __attribute__((aligned(256))) | Doc. | 0.1746 | 287,653,832 | 5,299,883 | 14,274 | 19,420 | **1.360** | 0.735 | ✅ |
| 2 | Alinhamento 16 KB temporários | Doc. | 0.1998 | 298,464,644 | 11,628,749 | 16,717 | 20,539 | 1.229 | 0.814 | ✅ |
| 3 | Tiling em i (2 partículas) | Doc. | 0.2435 | 245,173,122 | 2,375,541 | 20,983 | 31,376 | 1.495 | 0.669 | ✅ |
| 4 | Potências em árvore | Doc. | 0.2428 | 244,938,297 | 2,364,609 | 20,888 | 31,207 | 1.492 | 0.670 | ✅ |
| 5 | Pipelining manual | Doc. | 0.2062 | 298,219,834 | 11,636,469 | 16,823 | 21,547 | 1.261 | 0.793 | ✅ |
| 6 | Remoção de r2 > 0 | Doc. | 0.2430 | 245,047,036 | 2,292,393 | 20,949 | 31,606 | **1.499** | 0.667 | ✅ |
| 7 | Somas parciais por thread | Doc. | 0.2749 | 486,437,035 | 2,094,260 | 23,989 | 38,812 | **1.600** | 0.625 | ✅ |
| 8 | SVE 512 bits | Doc. | 1.6671 | 651,602,705 | 2,904,569 | 156,240 | 46,871 | 0.300 | 3.333 | ❌ **ERRO** |
| 9 | Fusão de Potential | Doc. | 0.5723 | 651,026,250 | 2,722,846 | 52,330 | 47,630 | 0.911 | 1.098 | ✅ |
| 10 | -mlow-precision-div | Doc. | 0.5732 | 651,649,837 | 2,741,639 | 52,383 | 47,966 | 0.916 | 1.092 | ✅ |
| 11 | schedule(static, 1) | Nova | 0.1782 | 284,282,235 | 5,579,100 | 14,651 | 20,436 | **1.395** | 0.717 | ✅ |
| 12 | SIMD em VelocityVerlet | Nova | 0.1744 | 284,231,975 | 5,256,963 | 14,266 | 19,229 | 1.348 | 0.742 | ✅ |
| 13 | Paralelização de initialize | Nova | 0.1720 | 282,720,012 | 5,210,549 | 14,099 | 18,862 | 1.338 | 0.747 | ✅ |

---

## Classificações

### 🥇 Melhores Tempos (48 threads)

| Rank | Otimização | Tempo (s) | % vs Baseline |
|------|-------------|-----------|---------------|
| 🥇 | **parallel_initialize** | **0.1720** | -1.5% |
| 🥈 | **simd_velocity_verlet** | **0.1744** | -0.1% |
| 🥉 | **schedule_static_1** | **0.1782** | +2.1% |
| 4 | aligned_256 | 0.1746 | **Baseline** |

---

### 🥇 Melhor IPC (48 threads)

| Rank | Otimização | IPC | % vs Baseline |
|------|-------------|-----|---------------|
| 🥇 | **partial_sums** | **1.600** | +17.6% |
| 🥈 | **remove_r2_check** | **1.499** | +10.2% |
| 🥉 | **schedule_static_1** | **1.395** | +2.6% |
| 4 | tiling_i | 1.495 | +10.0% |
| 5 | tree_powers | 1.492 | +9.7% |
| 6 | aligned_256 | **1.360** | **Baseline** |

---

### 🥇 Menor L1 Misses (48 threads)

| Rank | Otimização | L1 Misses | % vs Baseline |
|------|-------------|-----------|---------------|
| 🥇 | **remove_r2_check** | **245,047,036** | -14.8% |
| 🥈 | **tiling_i** | **245,173,122** | -14.8% |
| 🥉 | **tree_powers** | 244,938,297 | -14.9% |
| 4 | aligned_256 | **287,653,832** | **Baseline** |

---

### 🥇 Menor L2 Refills (48 threads)

| Rank | Otimização | L2 Refills | % vs Baseline |
|------|-------------|------------|---------------|
| 🥇 | **remove_r2_check** | **2,292,393** | -56.7% |
| 🥈 | **tiling_i** | **2,364,609** | -55.4% |
| 🥉 | **tree_powers** | 2,364,609 | -55.4% |
| 4 | partial_sums | 2,094,260 | -60.5% |
| 5 | aligned_256 | **5,299,883** | **Baseline** |

---

## Resumo numérico (48 threads)

```
Baseline (aligned_256):
  Tempo:       0.1746 s
  IPC:         1.360
  CPI:         0.735
  L1 Misses:   287.7 M
  L2 Refills:  5.3 M
  Ciclos:      14.27 G
  Instruções:  19.42 G

Melhor Tempo:   parallel_initialize (0.1720 s, -1.5%)
Melhor IPC:     partial_sums (1.600, +17.6%)
Menor L1 Miss: remove_r2_check (245.0 M, -14.8%)
Menor L2 Ref:  partial_sums (2.1 M, -60.5%)
```
