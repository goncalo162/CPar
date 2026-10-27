CC = gcc
SRC = src/
CFLAGS = -O3 -ffast-math

.DEFAULT_GOAL = md

md:     $(SRC)/MD.cpp
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

export OMP_NUM_THREADS ?= 48
run:
	./md     < inputdata.txt

runTest:
	taskset -c 0 perf stat -r 5 \
	  -e cpu_core/cycles/ \
	  -e cpu_core/instructions/ \
	  -e cpu_core/branches/ \
	  -e cpu_core/branch-misses/ \
	  -e cpu_core/L1-dcache-loads/ \
	  -e cpu_core/L1-dcache-load-misses/ \
	  ./scripts/run_md.sh

runRecord:
	taskset -c 0 perf record -F 1000 -g ./md < inputdata.txt