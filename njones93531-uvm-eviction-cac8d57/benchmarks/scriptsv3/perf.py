import itertools
import math
import config
import argparse

import numpy as np

from experiments_nolog import Experiment

def get_experiments(use_subset, smoke):
    psizes = config.PSIZES
    benchmarks = config.BENCHMARKS

    if smoke:
        psizes = config.PSIZES_SMOKE
        benchmarks = config.BENCHMARKS_SMOKE
    elif use_subset:
        psizes = config.PSIZES_SUBSET
        benchmarks = config.BENCHMARKS_SUBSET

    
    allocs = {"bfs-worst":3,
            "spmv-coo-twitter7":5,
            "sgemm":3 ,
            "2DCONV":2,
            "2MM":5,
            "3DCONV":2,
            "3MM":7,
            "ATAX":4,
            "BICG":5,
            "FDTD-2D":3,
            "GEMM":3,
            "GESUMMV":5,
            "GRAMSCHM":3,
            "MVT":5,
            "nw":2,
            "stream":3,
            "cg":9,
            "tealeaf":20,
    }
    
    bdir_base = "../strategied/"
    bdir_dict = {}
    for bmark in benchmarks: 
        bdir_dict[bmark] = f"{bdir_base}{bmark}/"

    benchmark_exe = "run_numa.sh"
    kernel_version = config.KERNEL_VERSION
    kernel_variant = "vanilla"
    experiments = []
    kernel_args = {}#,"uvm_perf_access_counter_momc_migration_enable":1,"uvm_perf_access_counter_granularity":"2m","uvm_perf_prefetch_enable":0, "uvm_perf_access_counter_threshold":"1"}
 
    for benchmark in benchmarks:
        benchmark_dir = bdir_dict[benchmark]
        kernel_args = {}
        nallocs = allocs[benchmark]
        policy_list = []

        #assemble policy list
        if benchmark == 'tealeaf':
            policy_list = ["ddmdddmmddmmddmmmmmm", "mmmmmmmmmmmmmmmmmmmm", "cccccccccccccccccccc","hhhhhhhhhhhhhhhhhhhh", "dddddmddddddddmmmmmm", "dmmdddmmdmmmdmmmmmmm", "dmmdddmmdmmmmmmmmmmm", "dddddhddddddddhhhhhh", "ddhdddhhddhhddhhhhhh", "dhhdddhhdhhhdhhhhhhh", "dhhdddhhdhhhhhhhhhhh", "dddddmddddddddmmmmmm", "ddddmdmmdmdddmmmmmmm", "dddmmmmmddmmdmmmmmmm", "dmdmdmmmdmdmmmmmmmmm"]
        elif benchmark == 'cg':
            policy_list = ["ccccccccc","mmmmmmmmm", "hhhhhhhhh", "ddddhdddd", "ddhdhdddd", "dhhdhdddd", "dhhdhdddd", "ddddmdddd", "ddmdmdddd", "dmmdmdddd", "dmmdmdddd", "ddddhdddd", "dmddhdddd", "mdhdhdddd", "dmhdhdddd"]
        else:
            policy_list = [''.join(combination) for combination in itertools.product(['m', 'h', 'd', 'c'], repeat=nallocs)]
            

        if smoke:
            policy_list = ['m' * nallocs, 'h' * nallocs, 'd' * nallocs, 'c' * nallocs]

        experiments.append(Experiment(benchmark, benchmark_exe, benchmark_dir, psizes, policy_list, benchmark_dir,\
                                      kernel_version, kernel_variant, kernel_args))


    return experiments

def main():
    parser = argparse.ArgumentParser()
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("-s", "--subset", action="store_true", help="Only compute a representative subset of data")
    selection.add_argument("--smoke", action="store_true", help="Run one size with three representative policies")
    parser.add_argument("-t", "--timeout", help="Adds a time limit to each experiment", default=0)

    args = parser.parse_args()

    experiments = get_experiments(args.subset, args.smoke)


    for experiment in experiments:
        #experiment.print_exp()
        print(experiment)
        if int(args.timeout) > 0:
            experiment.run(timeout=args.timeout)
        else:
            experiment.run()

if __name__ == "__main__":
    main()
