import argparse
import re
from pathlib import Path

CONFIG_FILE = "config.py"

def update_line(lines, var, new_val_str):
    pattern = re.compile(rf"^{var}\s*=")
    for i, line in enumerate(lines):
        if pattern.match(line.strip()):
            lines[i] = f"{var} = {new_val_str}\n"
            return True
    return False

def parse_args():
    parser = argparse.ArgumentParser(description="Edit config.py variables")
    parser.add_argument("--root", help="Set ROOT path")
    parser.add_argument("--vram-size", type=int, help="Set VRAM_SIZE in GB")
    parser.add_argument("--warmup-enabled", type=str, choices=["true", "false"], help="Enable or disable warmup")
    parser.add_argument("--kernel-version", help="Set KERNEL_VERSION")
    parser.add_argument("--kernel-variant", help="Set KERNEL_VARIANT")
    parser.add_argument("--kernel-license", choices=["kernel", "kernel-open"], help="Set KERNEL_LICENSE")
    parser.add_argument("--kernel-arg", action="append", help="Set a KERNEL_ARGS entry as key=value (can be used multiple times)")
    return parser.parse_args()

def main():
    args = parse_args()
    config_path = Path(CONFIG_FILE)

    if not config_path.exists():
        raise FileNotFoundError(f"{CONFIG_FILE} not found")

    lines = config_path.read_text().splitlines(keepends=True)

    if args.root:
        update_line(lines, "ROOT", f'"{args.root}"')
    if args.vram_size is not None:
        update_line(lines, "VRAM_SIZE", str(args.vram_size))
    if args.warmup_enabled:
        val = "True" if args.warmup_enabled.lower() == "true" else "False"
        update_line(lines, "WARMUP_ENABLED", val)
    if args.kernel_version:
        update_line(lines, "KERNEL_VERSION", f'"{args.kernel_version}"')
    if args.kernel_variant:
        update_line(lines, "KERNEL_VARIANT", f'"{args.kernel_variant}"')
    if args.kernel_license:
        update_line(lines, "KERNEL_LICENSE", f'"{args.kernel_license}"')
    if args.kernel_arg:
        # Find and parse existing KERNEL_ARGS
        kernel_line_idx = next(i for i, l in enumerate(lines) if l.strip().startswith("KERNEL_ARGS"))
        match = re.search(r"=\s*(\{.*\})", lines[kernel_line_idx])
        if match:
            kernel_dict_str = match.group(1)
            kernel_dict = eval(kernel_dict_str)  # This assumes the config is trusted
            for kv in args.kernel_arg:
                k, v = kv.split("=", 1)
                try:
                    v_eval = eval(v)
                except:
                    v_eval = v
                kernel_dict[k.strip()] = v_eval
            lines[kernel_line_idx] = f'KERNEL_ARGS = {kernel_dict}\n'

    config_path.write_text("".join(lines))

if __name__ == "__main__":
    main()
