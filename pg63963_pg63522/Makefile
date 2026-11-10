CC = gcc
SRC = src/
CFLAGS  = -x c -O3 -ffast-math -fopenmp
REPCFLAGS = -x c -O3 -ffast-math -fopenmp -g
LDFLAGS = -Wl,--build-id=sha1

BUS_PUS ?= 0,12,24,36

PERF_EVENTS = task-clock,cycles,instructions,br_pred,br_mis_pred,L1-dcache-loads,L1-dcache-load-misses,l2d_cache_refill,fp_dp_fixed_ops_spec,fp_dp_scale_ops_spec,fp_sp_fixed_ops_spec,fp_sp_scale_ops_spec,fp_hp_fixed_ops_spec,fp_hp_scale_ops_spec

BUS_EVENTS = bus_read_total_mem,bus_write_total_mem

.DEFAULT_GOAL = md
.PHONY: clean cleanBenchmarks run runTest runRecord

md: $(SRC)MD.cpp
	$(CC) $(CFLAGS) $(SRC)MD.cpp -lm $(LDFLAGS) -o md

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
	    a_traj.xyz \
	    bus_counters.txt

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
	@perf stat -a -C $(BUS_PUS) -e $(BUS_EVENTS) -o bus_counters.txt & \
	BUS_PID=$$!; sleep 0.5; \
	perf stat -e $(PERF_EVENTS) ./md < inputdata.txt; \
	kill -INT $$BUS_PID 2>/dev/null; wait $$BUS_PID 2>/dev/null; \
	echo; echo "== Contadores de memória (cores $(BUS_PUS)) =="; \
	cat bus_counters.txt

runRecord: $(SRC)MD.cpp
	$(CC) $(REPCFLAGS) $(SRC)MD.cpp -lm $(LDFLAGS) -o md
	perf record -F 1000 -g ./md < inputdata.txt