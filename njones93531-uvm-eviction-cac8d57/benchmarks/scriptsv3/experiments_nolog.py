#!/usr/bin/python3
import os
import sh
import stat
import subprocess
import sys
import time

import config

make_jobs = os.environ.get("MAKE_JOBS", str(min(os.cpu_count() or 1, 16)))

def skip_module_reload():
    return os.environ.get("SKIP_MODULE_RELOAD", "").strip().lower() in {
        "1", "true", "yes", "on"
    }

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

def run_privileged(command, *args):
    if os.geteuid() == 0:
        return sh.Command(command)(*args)
    return sh.sudo(command, *args)

def get_device_number(device_name):
    with open("/proc/devices") as devices:
        for line in devices:
            parts = line.strip().split()
            if len(parts) == 2 and parts[1] == device_name:
                return int(parts[0])
    return None

def ensure_device_node(device_name, path, minor):
    major = get_device_number(device_name)
    if major is None:
        raise RuntimeError(f"Kernel device {device_name} was not registered")

    if os.path.exists(path):
        device_stat = os.stat(path)
        if (stat.S_ISCHR(device_stat.st_mode)
                and os.major(device_stat.st_rdev) == major
                and os.minor(device_stat.st_rdev) == minor):
            return
        run_privileged("rm", "-f", path)

    run_privileged("mknod", "-m", "0666", path, "c", str(major), str(minor))

def load_module(module, args={}):
    if os.path.exists("/sys/module/nvidia_uvm"):
        try:
            run_privileged("rmmod", "nvidia_uvm")
        except Exception as e:
            raise RuntimeError(
                "Could not unload nvidia_uvm. Stop display/CUDA processes using the "
                "GPU, then retry. The experiment runner will not force-unload it."
            ) from e
    print(f"insmod {module}", args)
    arg_strs = [f"{key}={value}" for key, value in args.items()] 
    run_privileged("insmod", module, *arg_strs)
    ensure_device_node("nvidia-uvm", "/dev/nvidia-uvm", 0)
    ensure_device_node("nvidia-uvm", "/dev/nvidia-uvm-tools", 1)
    if config.WARMUP_ENABLED:
        p = subprocess.Popen([f'{config.WARMUP_DIR}/{config.WARMUP_EXE}'], stdout=subprocess.PIPE)
        # insert warmup error logging?
        p.wait()

def install_module(path):
    print(f"Building kernel module at {path}")
    oldpwd = os.getcwd()
    os.chdir(path)
    sh.make("modules", f"-j{make_jobs}")
    os.chdir(oldpwd)

kernel_arg_dict={"uvm_perf_prefetch_enable": "nopf","uvm_perf_access_counter_batch_count": "", "uvm_perf_access_counter_granularity": "gran", "uvm_perf_access_counter_threshold": "thold", "uvm_perf_access_counter_mimc_migration_enable": "mimc", "uvm_perf_access_counter_momc_migration_enable": "momc", "uvm_perf_prefetch_threshold":"thold"}
def kernel_args_string(kernel_args):
    if len(kernel_args.keys()) == 0:
        return ""
    return "_".join([kernel_arg_dict[key] for key in kernel_args.keys()]) + "_"

class Experiment:

    def __init__(self, benchmark, benchmark_exe, benchmark_dir, psizes, policies,\
                 benchmark_arg_desc, kernel_version, kernel_variant, kernel_args):
        self.benchmark = benchmark
        self.benchmark_exe = benchmark_exe
        self.benchmark_dir = benchmark_dir
        self.psizes = psizes
        self.policies = policies
        self.kernel_version = kernel_version
        self.kernel_variant = kernel_variant
        self.kernel_args = kernel_args
          
    def get_benchmark_arg_desc(self, policy, psize):
        return f"{policy}_{psize}_{self.benchmark}"

    def __str__(self):
        return (f"Benchmark: {self.benchmark}\n"
                f"Benchmark Executable: {self.benchmark_exe}\n"
                f"Benchmark Directory: {self.benchmark_dir}\n"
                f"Psizes: {self.psizes}\n"
                f"Policies: {self.policies}\n"
                f"Kernel Version: {self.kernel_version}\n"
                f"Kernel Variant: {self.kernel_variant}\n"
                f"Kernel Arguments: {self.kernel_args}\n")


    def _run(self, clear, psize, policy, timeout=float(os.environ['TIMEOUT'])): 
            logdir_base = f"{self.kernel_version}_{self.kernel_variant}_{kernel_args_string(self.kernel_args)}{self.get_benchmark_arg_desc(policy, psize)}"
            logdir = f"{self.benchmark_dir}/log_{logdir_base}"
            print("Running experiment:", logdir_base)

            variant_dir = f"{config.DRIVER_DIR}/{self.kernel_version}/{self.kernel_variant}"
            module_dir = f"{variant_dir}/{config.KERNEL_LICENSE}"
            build_dir = variant_dir if os.path.exists(f"{variant_dir}/Makefile") else module_dir
            if skip_module_reload():
                print(
                    "SKIP_MODULE_RELOAD is set; using the currently loaded "
                    "nvidia_uvm module"
                )
            else:
                install_module(build_dir)

                try:
                    load_module(f"{module_dir}/nvidia-uvm.ko", self.kernel_args)
                except Exception as e:
                    raise RuntimeError(
                        "Failed to load the experimental nvidia_uvm module. "
                        "Inspect dmesg for a version, signature, or symbol error."
                    ) from e


            oldpwd = os.getcwd()
            os.chdir(self.benchmark_dir)

            #TODO fix this for benchmarks that don't use make explicitly
            print("Build benchmark")
            sh.make(f"-j{make_jobs}")
            print("Starting execution")
            psize_gb = int(int(psize) * config.VRAM_SIZE / 100)
            print(f"taskset 0xFFFFFFFF ./{self.benchmark_exe} {psize_gb} -p {policy}")

            print(f"Setting environment variable TIMEOUT={timeout}")
            env = os.environ.copy()
            env['TIMEOUT'] = repr(timeout)
            start_time = time.monotonic()
            p = subprocess.Popen(["taskset", "0xFFFFFFFF", f'./{self.benchmark_exe}', str(psize_gb), '-p', policy], stdout=subprocess.PIPE, preexec_fn=os.setsid, env=env)
            output, err = p.communicate()
            print("Waiting on process to die")
            p.wait()
            execution_time = time.monotonic() - start_time
            print(f"Execution time: {execution_time} seconds")



            print("out:", output)
            eprint("err:", err)

            os.chdir(oldpwd)
            print("Finished", logdir_base)
            return execution_time

    def run(self, clear=False, timeout=1000000000):
        for psize in self.psizes:
            print(f"Starting Experiment Set {self.benchmark} {psize}")
            local_policies = self.policies.copy()
            # find baseline policy
            target = 'm' * len(local_policies[0])
            for policy in local_policies:
                if policy == target:
                    local_policies.remove(policy)
                    break
            # run and time baseline first; set timeout for following policies based on this.
            baseline = self._run(clear, psize, target)
            print(f"Experiment set {self.benchmark} {psize}: Measured baseline execution {target} at {baseline} seconds. Using {2 * baseline} as timeout for remaining experiments.")
            for policy in local_policies:
                self._run(clear, psize, policy, min(2 * baseline, int(timeout)))
