# UVM eviction artifact

This checkout includes a port of the actively used experiment paths to NVIDIA
Linux driver **595.71.05**:

- `drivers/x86_64-595.71.05/vanilla`: unmodified NVIDIA open kernel modules
- `drivers/x86_64-595.71.05/faults-new`: the fault, prefetch, eviction, and VA
  range logger ported to the 595.71.05 UVM sources

The port is based on NVIDIA's official
[`595.71.05` open-gpu-kernel-modules tag](https://github.com/NVIDIA/open-gpu-kernel-modules/tree/595.71.05).
The driver version must match the running host driver exactly.

## Requirements

- A Linux GPU host running the **open** NVIDIA 595.71.05 kernel modules
- Docker Engine plus NVIDIA Container Toolkit (`docker run --gpus all`)
- Headers for the running host kernel
- No active CUDA/display process holding `nvidia_uvm` when an experiment swaps it
- Secure Boot/module-signature enforcement disabled, or a locally configured
  signing process for the newly built `nvidia-uvm.ko`

Docker supplies the userspace build/runtime environment, but it cannot replace
or hide the host kernel driver. The experiment container is privileged because
it unloads the host `nvidia_uvm` module and inserts the matching experimental
module.

Check the host before starting:

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader
modinfo -F license nvidia
docker run --rm --gpus all nvidia/cuda:13.2.0-base-ubuntu22.04 nvidia-smi
```

The first command must print `595.71.05`. The module license should identify the
open driver (`Dual MIT/GPL`). Install headers if this path is missing:

```bash
test -e "/lib/modules/$(uname -r)/build/Makefile"
```

## Start the container

From the repository root on the GPU host:

```bash
./docker/setup.sh
```

`setup.sh` validates the driver flavor/version and kernel headers, builds a
versioned Docker image from NVIDIA's CUDA 13.2 image, mounts this checkout and
the host headers, and opens a shell at `/uvm-eviction`.

## Run experiments

Start with one end-to-end fault-logging smoke test:

```bash
./scripts/generate-faults.sh --smoke
```

Then smoke-test the performance runner (one size and three policies):

```bash
./scripts/evaluate-perf.sh --smoke
```

Use `--subset` for the representative sets, or omit both switches for the full
experiment sets. The default timeout is 12,000 seconds and can be changed with
`-t SECONDS`, for example:

```bash
./scripts/generate-faults.sh --subset -t 1800
```

The fault runner uses `faults-new`; the performance runner uses the 595.71.05
`vanilla` UVM module. Configuration is in
`benchmarks/scriptsv3/config.py`. The container entrypoint fills in the mounted
repository path and detected GPU memory size automatically.

The first module build may take several minutes. If unloading `nvidia_uvm`
fails, stop all CUDA jobs and any display manager using that GPU, then retry.
The runner deliberately does not force-unload an in-use kernel module.
Build parallelism is capped at 16 jobs; set `MAKE_JOBS` to override it.

## Restore the stock UVM module

The inserted UVM module belongs to the host even after the container exits.
Restore the installed module on the host after the experiments:

```bash
sudo rmmod nvidia_uvm
sudo modprobe nvidia_uvm
```

Rebooting also restores the installed module.

## Scope of this port

The top-level artifact scripts currently exercise the `faults-new` logger and
the `vanilla` module, so those are the two 595.71.05 variants ported here. The
older `preempt`, `preempt-conservative`, `eviction`, access-counter, and syscall
trees remain at their original driver versions and are not selected by these
scripts. There is no variant named `adaptive` in this checkout; if your adaptive
implementation lives outside these two active paths, its source changes still
need to be rebased separately onto the 595.71.05 vanilla tree.

## Output and analysis

Fault logs are written beneath each benchmark's `log_*` directory. Plotting and
conversion tools are under `tools/`, including `tools/fault_plotsv2`,
`tools/plotv2`, and `tools/sys2csv`.

The original experiments used a Titan V, an AMD EPYC 7551P host, Fedora 33,
CUDA 11.2, and driver 460.27.04. Results on newer hardware, CUDA 13.2, driver
595.71.05, and a newer Linux kernel should be treated as a reproduction on a new
platform rather than bit-for-bit comparable measurements.
