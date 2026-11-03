CC = gcc
SRC = src/
CFLAGS  = -x c -O3 -ffast-math -fopenmp

.DEFAULT_GOAL = md
.PHONY: clean cleanBenchmarks run runTest runRecord

md: $(SRC)MD.cpp
	$(CC) $(CFLAGS) $(SRC)MD.cpp -lm -o md

clean:
	rm -f ./md \
		cp_average.txt \
		0_average.txt \
		cp_output.txt \
		0_output.txt \
		a_average.txt \
		a_output.txt \
		cp_traj.xyz \
		0_traj.xyz \
		a_traj.xyz

cleanBenchmarks: clean
	rm -rf benchmark_* \
		   single_* \
		   report_* \
	       out.* \
	       err.*

export OMP_NUM_THREADS ?= 48

run: md
	./md < inputdata.txt

runTest:
	perf stat \
		-e task-clock \
		-e cycles \
		-e instructions \
		-e br_pred \
		-e br_mis_pred \
		-e L1-dcache-loads \
		-e L1-dcache-load-misses \
		-e fp_dp_fixed_ops_spec \
		-e fp_sp_fixed_ops_spec \
		-e fp_hp_fixed_ops_spec \
		-e fp_scale_ops_spec \
		-e fp_fma_spec \
		./md < inputdata.txt

runRecord:
	perf record -F 1000 -g ./md < inputdata.txt