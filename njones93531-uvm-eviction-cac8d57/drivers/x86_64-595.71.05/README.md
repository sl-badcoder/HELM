# NVIDIA 595.71.05 port

Both trees originate from NVIDIA's official `595.71.05`
`open-gpu-kernel-modules` tag.

- `vanilla` is an unchanged source snapshot.
- `faults-new` adds the artifact's UVM event logger and `/dev/hpcs_logger`
  interface.

Build either tree from its variant root so the generated NVIDIA source objects
and the open kernel interface objects are built together:

```bash
cd drivers/x86_64-595.71.05/faults-new
make modules -j"$(nproc)"
```

The UVM output is `kernel-open/nvidia-uvm.ko`. It is only load-compatible with
the exact 595.71.05 open NVIDIA base modules and must be rebuilt against the
headers for the running Linux kernel.
