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

## Tests & Visual Diagnostics

```sh
python3 -B -m unittest -v scripts/test_ethan_capped_run.py
```

The test suite validates cgroup memory limits, namespace PID 1 process reaping, signal containment, and graceful degradation across unprivileged environments. Continuous integration executes on Ubuntu runners (`.github/workflows/ci.yml`).

### Visual Diagnostics Walkthrough

```text
┌────────────────────────────────────────────────────────────────────────────┐
│ $ bash scripts/ethan_capped_run.sh python3 -c "print('sandboxed')"         │
│ [CGROUP-SANDBOX] Initializing Linux namespace & systemd user scope         │
│ [*] Resource Limits: Memory=300M, Swap=0M, CPUQuota=100%                   │
│ [*] Namespace Isolation: PID=private, Net=unshared, User=mapped            │
│ -------------------------------------------------------------------------- │
│ sandboxed                                                                  │
│ ══════════════════════════════════════════════════════════════════════════ │
│ [STATUS] Process exited cleanly | Reaped orphaned tasks | Resources freed │
└────────────────────────────────────────────────────────────────────────────┘
```

## Engineering Standards & Magi Bible

All scripts, resource governance wrappers, and documentation follow the **[Magi Bible: Engineering Foundations & Safety Standards for AI Coding](MAGI_BIBLE.md)**:
- **Rule 16 Commenting Invariant:** Code contains comprehensive structural headers and inline rationale.
- **Fail-Closed Security:** Refuses unisolated execution by default if kernel namespaces fail; requires explicit opt-in for host mode.
- **Zero Secrets & Leak-Scrubbed:** Free of private tokens, paths, or personal hostnames.
- **Visual Diagnostics:** Clear terminal walkthrough cards documenting operational behavior.
