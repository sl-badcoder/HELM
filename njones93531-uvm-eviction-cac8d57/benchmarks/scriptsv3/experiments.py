#!/usr/bin/python3
import os
import sh
import stat
import subprocess
import sys

import config

from copy import deepcopy

slurm_output_directory = f'{config.SCRIPTSDIR}/fault_plot_out/'
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
    # Replacing UVM requires every process using CUDA to be stopped first.
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
    print(f"Installing kernel module at {path}")
    oldpwd = os.getcwd()
    os.chdir(path)
    sh.make("modules", f"-j{make_jobs}")
    #sh.sudo("make", "modules_install", "-j")
    os.chdir(oldpwd)

def init_syslogger(logfile):
    ensure_device_node("hpcs_logger", "/dev/hpcs_logger", 0)
    oldpwd = os.getcwd()
    os.chdir(config.SYSLOG_PATH)
    sh.make(f"-j{make_jobs}")
    os.chdir(oldpwd)
    process = subprocess.Popen([f"{config.SYSLOG_PATH}/{config.SYSLOG_EXE}", logfile])#, creationflags=subprocess.DETACHED_PROCESS)
    return process

def close_syslogger(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    
kernel_arg_dict={"uvm_perf_prefetch_enable": "nopf","uvm_perf_access_counter_batch_count": "", "uvm_perf_access_counter_granularity": "gran", "uvm_perf_access_counter_threshold": "thold", "uvm_perf_access_counter_mimc_migration_enable": "mimc", "uvm_perf_access_counter_momc_migration_enable": "momc", "uvm_perf_prefetch_threshold":"thold", "hpcs_log_short" : "", "hpcs_log_prefetching":  "", "hpcs_log_evictions": ""}
def kernel_args_string(kernel_args):
    parts = [kernel_arg_dict[key] for key in kernel_args.keys() if kernel_arg_dict[key]]
    if len(parts) == 0:
        return ""
    return "_".join(parts) + "_"

class Experiment:

    def __init__(self, benchmark, benchmark_exe, benchmark_dir, benchmark_args, \
                 kernel_version, kernel_variant, kernel_args):
        self.benchmark = deepcopy(benchmark)
        self.benchmark_exe = deepcopy(benchmark_exe)
        self.benchmark_dir = deepcopy(benchmark_dir)
        self.benchmark_args = deepcopy(benchmark_args)
        self.kernel_version = deepcopy(kernel_version)
        self.kernel_variant = deepcopy(kernel_variant)
        self.kernel_args = deepcopy(kernel_args)

    def get_arg_desc(self, psize):
        return f"{psize}_{self.benchmark}"
    
    def __str__(self):
        return f"{self.kernel_version}_{self.kernel_variant}_{kernel_args_string(self.kernel_args)}{self.benchmark}"

    def run(self, clear=False, txt_only=False):
        klogs = []
        for arg in self.benchmark_args:
            logdir_base = f"{self.kernel_version}_{self.kernel_variant}_{kernel_args_string(self.kernel_args)}{self.get_arg_desc(arg)}"
            logdir = f"{self.benchmark_dir}/log_{logdir_base}"
            klog = f"{logdir}/{self.benchmark}_klog"
            plog = f"{logdir}/{self.benchmark}_perf.txt"

            klogs.append(klog)
            print("Running experiment:", logdir_base)
            if not clear and os.path.exists(klog) and os.path.exists(plog):
                print("Existing experiment log found")
                return
            if not os.path.exists(logdir):
                os.makedirs(logdir)
            if os.path.exists(klog):
                os.remove(klog)
            if os.path.exists(plog):
                os.remove(plog)
            
            variant_dir=f"{config.DRIVER_DIR}/{self.kernel_version}/{self.kernel_variant}"
            module_dir=f"{variant_dir}/{config.KERNEL_LICENSE}"
            build_dir = variant_dir if os.path.exists(f"{variant_dir}/Makefile") else module_dir
            if skip_module_reload():
                print(
                    "SKIP_MODULE_RELOAD is set; using the currently loaded "
                    "nvidia_uvm module"
                )
            else:
                install_module(build_dir)

                # Load module
                try:
                    load_module(f"{module_dir}/nvidia-uvm.ko", self.kernel_args)
                except Exception as e:
                    raise RuntimeError(
                        "Failed to load the experimental nvidia_uvm module. "
                        "Inspect dmesg for a version, signature, or symbol error."
                    ) from e


            slog_proc = init_syslogger(klog)
            oldpwd = os.getcwd()
            os.chdir(self.benchmark_dir)

            #TODO fix this for benchmarks that don't use make explicitly
            print("Build benchmark")
            sh.make(f"-j{make_jobs}")
            print("Starting execution")
            #TODO fix this for benchmarks that need more than just their problem size
            psize_gb = int(int(arg) * config.VRAM_SIZE / 100)
            command = ["taskset", "0xFFFFFFFF", f'./{self.benchmark_exe}'] + [str(psize_gb)]
            #command = ["taskset", "-c", "4,5", f'./{self.benchmark_exe}'] + self.benchmark_args
            p = subprocess.Popen(command, stdout=subprocess.PIPE)
            print(f"Running command {command}")
            output, err = p.communicate()
            exit_code = p.wait()

            close_syslogger(slog_proc)

            print("out:", output)
            eprint("err:", err)
            eprint("exit code:", exit_code)
            
            os.chdir(oldpwd)
            #self.launch_fault_plotting_job(klog, arg)
        #self.launch_fault_scaling_plotting_job(klogs)

    def launch_fault_plotting_job(self, klog, arg):
        os.makedirs(slurm_output_directory, exist_ok=True)
        experiment_str = f"{self.kernel_version}_{self.kernel_variant}_{kernel_args_string(self.kernel_args)}{self.get_arg_desc(arg)}"        
        print("Finished, launching plotting job", experiment_str)
        try:
            # Using the sh.sbatch function to submit the job script
            #print(sh.sbatch(script_file, klog))
            sh.sbatch(f"--job-name=fault_plot_{experiment_str}",\
                     f"--output={slurm_output_directory}/{experiment_str}.out",\
                     "--partition=hsw", "--nodes=1", "--exclusive", "--time=08:00:00",\
                     f"--chdir={config.ROOT}/tools/fault_plotsv2/",\
                     f"--wrap=python {config.ROOT}/tools/fault_plotsv2/fault_plot.py {klog}")
        except sh.ErrorReturnCode as e:
            # Handle errors returned from sbatch
            print("Error submitting job:", e)
    
    def launch_fault_scaling_plotting_job(self, klogs):
        os.makedirs(slurm_output_directory, exist_ok=True)
        experiment_str = f"{self.kernel_version}_{self.kernel_variant}_{'-'.join(self.benchmark_args)}_{self.benchmark}"
        print("Finished, launching scaling plotting job", experiment_str)
        try:
            # Using the sh.sbatch function to submit the job script
            #print(sh.sbatch(script_file, klog))
            sh.sbatch(f"--job-name=fault_scaling_plot_{experiment_str}",\
                     f"--output={slurm_output_directory}/{experiment_str}.out",\
                     "--partition=hsw", "--nodes=1", "--exclusive", "--time=08:00:00",\
                     f"--chdir={config.ROOT}/tools/fault_plotsv2/",\
                     f"--wrap=python {config.ROOT}/tools/fault_plotsv2/fault_scaling_plot.py {' '.join(klogs)}")
        except sh.ErrorReturnCode as e:
            # Handle errors returned from sbatch
            print("Error submitting job:", e)
