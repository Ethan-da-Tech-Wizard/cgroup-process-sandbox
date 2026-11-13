# Cgroup Process Sandbox

A Linux shell wrapper for running a command with optional namespace isolation and resource controls. It combines `unshare` with a systemd user scope when the relevant host facilities are available.

## How it works

- By default, the wrapper checks whether user, PID and network namespaces are available; it refuses that mode if the check fails.
- When a systemd user bus is available, the wrapper invokes `systemd-run` with a memory limit, swap limit and CPU quota. `ETHAN_CAP` changes the default memory limit.
- The wrapper includes a GPU-temperature wait and file-lock based concurrency slots. Temperature checks are best effort and can fail open.
- `ETHAN_HOST=1` skips namespace isolation. If the systemd user bus is unavailable, the command runs without the systemd cgroup limits.

## Before running

Read [the wrapper](scripts/ethan_capped_run.sh) and [the test file](scripts/test_ethan_capped_run.py), and check the requirements on the target Linux host. The repository also contains a host-configuration script; inspect its effects before using it.

```sh
bash scripts/ethan_capped_run.sh <command> [arguments...]
```

The script refers to `ethan_mac_capped_run.py` on macOS, but that file is not present in this repository's `scripts/` directory. The macOS path is therefore not established by this repository alone.

## Limitations

Namespace and cgroup behavior depend on host configuration and permissions. This wrapper does not guarantee host stability, complete isolation, or protection against every untrusted workload. Confirm which controls actually took effect for each run.
