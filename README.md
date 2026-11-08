<!--
Program: Linux cgroup v2 Resource Governance & Namespace Sandbox
Programmer: Ethan Kilmer
Last Modified: 11/08/2026
Purpose: Execute commands inside hard memory caps and isolated Linux namespaces to prevent desktop freezes.
-->

# Linux cgroup v2 Resource Governance & Namespace Isolation Sandbox

A production-grade Linux process isolation and resource governance harness. It combines **systemd cgroup v2**, **unprivileged user/PID/network namespaces (`unshare`)**, **PID 1 zombie reaping**, **OOM priority adjustment**, and **thermal hysteresis gating** to execute untrusted, heavy, or test workloads without risking host workstation lockups, desktop freezes, or process signal leakage.

---

## Architecture Overview

```
+----------------------------------------------------------------------------------------------------+
| Host Workstation (Wayland/X11 Desktop, IDE, Browser, System Daemons)                               |
|                                                                                                    |
|  +----------------------------------------------------------------------------------------------+  |
|  | systemd-run --user --scope (cgroup v2 Enforcement)                                           |  |
|  |   * MemoryMax=3G             -> Hard memory ceiling; cgroup OOM killer terminates run        |  |
|  |   * MemorySwapMax=0          -> Zero swap usage permitted; eliminates swap thrashing        |  |
|  |   * CPUQuota=400%            -> Maximum 4 CPU cores bandwidth; preserves UI responsiveness  |  |
|  |   * ManagedOOMMemoryPressure -> PSI memory pressure monitoring via systemd-oomd              |  |
|  |                                                                                              |  |
|  |  +----------------------------------------------------------------------------------------+  |  |
|  |  | Rootless Linux Namespaces (unshare --user --map-root-user --pid --fork --net)          |  |  |
|  |  |                                                                                        |  |  |
|  |  |  +----------------------------------------------------------------------------------+  |  |  |
|  |  |  | PID 1 (Bash Subshell)                                                            |  |  |  |
|  |  |  |   * Sets /proc/self/oom_score_adj = 500 (kernel sacrifices sandbox first)        |  |  |  |
|  |  |  |   * Brings loopback UP (ip link set lo up -> 127.0.0.1 available for tests)       |  |  |  |
|  |  |  |   * Reaps orphaned grandchildren (prevents <defunct> zombie storm)                |  |  |  |
|  |  |  |                                                                                  |  |  |  |
|  |  |  |  +----------------------------------------------------------------------------+  |  |  |  |
|  |  |  |  | Sandboxed Target Process (e.g. pytest, python3, build runner)              |  |  |  |  |
|  |  |  |  |   * Ephemeral HOME: /tmp/ethan-sandbox-home.XXXXXX                         |  |  |  |  |
|  |  |  |  |   * Sanitized Environment (env -i)                                         |  |  |  |  |
|  |  |  |  |   * Private /proc mount (host processes completely invisible)              |  |  |  |  |
|  |  |  |  |   * Signal blast radius trapped: kill(-1) cannot escape                    |  |  |  |  |
|  |  |  |  +----------------------------------------------------------------------------+  |  |  |  |
|  |  +----------------------------------------------------------------------------------------+  |  |
|  +----------------------------------------------------------------------------------------------+  |
+----------------------------------------------------------------------------------------------------+
```

---

## The Problem: Why Workstations Freeze

On modern developer machines, runaway processes (e.g., test suites with mock loops, memory-leaking data pipelines, parallel compilation jobs, or unbounded local AI agents) can easily crash the host system:

1. **Swap Thrashing & Desktop Lockup:** When RAM fills up, the Linux kernel pushes active dirty pages to swap. When swap bandwidth saturates disk I/O queues, desktop compositors (GNOME, KDE, Wayland, X11) cannot read UI assets, input events freeze, and the entire workstation becomes unresponsive for minutes or hours.
2. **Process Signal Blasts:** Accidental calls such as `kill(-1, SIGTERM)` or `killpg(1, SIGKILL)` in test mocks or cleanup scripts broadcast signals to *every process the user owns*, terminating IDEs, browser sessions, and login shells.
3. **Zombie Process Accumulation:** Processes executing in private PID namespaces without a proper init process leave orphaned children as `<defunct>` zombies. Accumulating tens of thousands of zombies inflates kernel task structures and makes standard tools like `ps`, `pgrep`, and `/proc` traversals peg the CPU at 100%.
4. **Thermal Cascade:** On modern laptops with shared CPU and GPU heatsinks, heavy multi-core CPU test runs dump heat directly into the cooling loop, driving GPU temperatures into thermal throttling or triggering emergency watchdog shutdowns.

---

## Core Mechanisms

### 1. systemd cgroup v2 Resource Enforcement

The runner wraps every execution in an ephemeral user scope via `systemd-run`:

* **`MemoryMax=3G` (Configurable via `ETHAN_CAP`):**
  Defines the hard memory limit in the cgroup v2 `memory.max` controller. If the combined memory of all processes in the scope reaches this boundary, the kernel initiates page reclamation. If memory cannot be freed, the cgroup OOM killer immediately terminates processes inside the sandbox without touching any other application on the host.
* **`MemorySwapMax=0`:**
  Sets `memory.swap.max` to zero. This is the **critical safeguard against desktop lockups**: by completely forbidding the sandboxed cgroup from writing to swap, runaway processes hit the memory ceiling instantly and get terminated immediately by the cgroup OOM killer, completely bypassing disk I/O thrashing.
* **`CPUQuota=400%` (Configurable via `ETHAN_CPU`):**
  Enforces a strict CPU bandwidth quota (`cpu.max`). 400% corresponds to 4 full CPU core equivalents. Even if a test suite spins up 32 threads in an infinite loop, it is constrained to 400% time slices, leaving remaining CPU cores completely free for desktop compositing and interactive user tasks.
* **`ManagedOOMMemoryPressure=kill` & `ManagedOOMMemoryPressureLimit=40%`:**
  Integrates with `systemd-oomd` using Linux kernel PSI (Pressure Stall Information). If task stall time waiting on memory exceeds 40%, `systemd-oomd` terminates the offending unit proactively before severe thrashing occurs.

### 2. Rootless Namespace Sandboxing (`unshare`)

Without requiring root privileges or `sudo`, the sandbox uses `unshare` to decouple the execution context from the host:

* **`--user` & `--map-root-user`:**
  Instantiates a private user namespace and maps the caller's unprivileged host UID/GID to UID 0 (root) inside the sandbox. This allows the sandbox to mount a private `/proc` and configure internal network interfaces while retaining zero elevated privileges on the host filesystem.
* **`--pid` & `--fork`:**
  Spawns the workload in an isolated PID namespace. The target command cannot view, inspect, or signal any host processes. Calls like `kill(-1)` or `killpg(1)` are strictly bounded within the namespace.
* **`--net` & Loopback Initialization (`ip link set lo up`):**
  Detaches all host network adapters (Ethernet, Wi-Fi, VPNs, tunnels). In a fresh network namespace, the loopback device (`lo`) is down by default. The sandbox executes `ip link set lo up` to enable `127.0.0.1` and `::1` binding for local mock servers and inter-process communication, while ensuring zero access to external networks or the LAN.
* **`--mount-proc`:**
  Mounts a private `/proc` virtual filesystem matching the isolated PID namespace, ensuring tools like `ps`, `top`, and `/proc/<pid>` reflect only the sandbox processes.
* **Ephemeral `$HOME` & Environment Sanitization:**
  Generates a temporary directory (`/tmp/ethan-sandbox-home.XXXXXX`) as `$HOME` and uses `env -i` to strip ambient secrets, tokens, and configuration, passing only explicit variables (`PATH`, `LANG`, `PYTHONPATH`).

### 3. PID 1 Zombie Reaping Architecture

In Linux, when a child process terminates, its metadata remains in the process table until its parent calls `wait()` or `waitpid()`. If the parent process exits before its children, those children become orphans and are adopted by the root process of their PID namespace: **PID 1**.

**Why replacing the shell with `exec` fails:**
If `exec "$@"` were used, the target command (e.g. `python3` or `node`) would become PID 1. Most application runtimes and test runners do not implement an init daemon's SIGCHLD signal handler and event loop. Consequently, any orphaned grandchild processes (such as git sub-commands, subshells, or background helpers) remain as `<defunct>` zombies until the entire namespace terminates.

**The Solution:**
The sandbox retains a lightweight Bash process as PID 1. Bash automatically intercepts SIGCHLD and reaps terminated orphaned children continuously, maintaining a clean process table and preventing CPU-intensive `/proc` traversal degradation.

### 4. OOM Priority Adjustment

The subshell executes:
```bash
echo 500 > /proc/self/oom_score_adj
```
Linux `/proc/[pid]/oom_score_adj` ranges from `-1000` (completely immune) to `+1000` (always killed first). By setting this value to `500`, the sandbox designates itself as sacrificial: if global host memory pressure ever spikes, the kernel terminates the sandbox before touching desktop applications, editors, or login sessions.

### 5. Thermal Hysteresis Gating & Concurrency Control

* **Thermal Gating (`nvidia-smi`):**
  If NVIDIA GPU telemetry is present, the runner checks GPU temperature before launching. If the temperature exceeds `ETHAN_THERMAL_GATE` (default 88°C), execution pauses in 5-second intervals (up to `ETHAN_THERMAL_WAIT`, default 120s) to let fans dissipate chassis heat. If telemetry is absent or times out, it fails open to prevent deadlocks.
* **Advisory Concurrency Slots (`flock`):**
  Advisory kernel file descriptor locks restrict concurrent executions to `ETHAN_SLOTS` (default 2), preventing multiple background agents from overwhelming the CPU and causing thermal throttling.

---

## Repository Structure

```
.
├── README.md
└── scripts
    ├── ethan_capped_run.sh           # Main sandbox runner with systemd + namespace isolation
    ├── ethan_memory_safety_setup.sh  # One-time host configuration script (swap + systemd-oomd)
    └── test_ethan_capped_run.py      # Automated unit test suite verifying sandboxing & cgroups
```

---

## Quickstart

### Prerequisites

* Linux with kernel >= 5.8 (cgroup v2 unified hierarchy enabled).
* `systemd` with user session support (`systemd --user`).
* `util-linux` (`unshare`, `flock`).
* Optional: `nvidia-smi` for thermal gating.

### Usage

Run any command inside the sandbox:

```bash
# Run a Python test suite under a 3G cap and isolated namespace
./scripts/ethan_capped_run.sh python3 -m unittest -v

# Run an untrusted build or script
./scripts/ethan_capped_run.sh make -j4
```

### Environment Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `ETHAN_CAP` | `3G` | Memory ceiling for cgroup v2 `MemoryMax` (e.g. `500M`, `6G`). |
| `ETHAN_CPU` | `400%` | CPU quota for cgroup v2 `CPUQuota` (e.g. `200%` = 2 cores). |
| `ETHAN_HOST` | `0` | Set to `1` to bypass namespace sandboxing (for host GPU/display access). |
| `ETHAN_THERMAL_GATE` | `88` | GPU temperature (°C) threshold before pausing execution. |
| `ETHAN_THERMAL_WAIT` | `120` | Max seconds to wait for thermal cooling before running anyway (`0` disables). |
| `ETHAN_SLOTS` | `2` | Max concurrent sandbox executions (`0` disables slot concurrency limit). |
| `ETHAN_SLOT_WAIT` | `1800` | Max seconds to wait for an available concurrency slot before proceeding. |

### Host Mode Escape Hatch

When a command requires direct access to host GPU acceleration (CUDA/Vulkan), Wayland/X11 display sockets, or the host network stack, run with `ETHAN_HOST=1`:

```bash
ETHAN_HOST=1 ./scripts/ethan_capped_run.sh ./run_local_llm_inference
```
In host mode, cgroup v2 memory and CPU caps remain fully enforced, but namespace isolation is bypassed.

---

## Host System Preparation (`ethan_memory_safety_setup.sh`)

To ensure host stability under memory pressure, `ethan_memory_safety_setup.sh` configures:
1. An 8 GiB managed swap file (`/swapfile`) with `pri=10`.
2. Kernel swappiness tuned to `vm.swappiness = 30` (swaps only under true pressure).
3. VFS cache pressure set to `vm.vfs_cache_pressure = 50` (preserves directory/inode caches).
4. `systemd-oomd` drop-in configuration (`SwapUsedLimit=90%`, `DefaultMemoryPressureLimit=50%`).

### Preview changes (read-only):
```bash
bash scripts/ethan_memory_safety_setup.sh --check
```

### Apply configuration (requires root):
```bash
sudo bash scripts/ethan_memory_safety_setup.sh
```

---

## Running the Unit Tests

The test suite validates:
* Memory cap enforcement and clean cgroup SIGKILL termination on runaway memory growth.
* `/proc/self/oom_score_adj` adjustment to 500.
* PID 1 namespace isolation and automatic orphaned grandchild zombie reaping.
* Signal containment (verifying `killpg(1)` cannot reach host processes).
* Network loopback isolation and ephemeral `$HOME` creation.
* Concurrency slot locking and timeout behavior.

Execute the test suite:
```bash
python3 -B -m unittest scripts/test_ethan_capped_run.py
```

---

## License

MIT License. Developed by Ethan Kilmer / TWU LLC.
