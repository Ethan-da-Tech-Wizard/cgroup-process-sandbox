#!/usr/bin/env bash
# ==============================================================================
# Linux cgroup v2 Resource Governance & Namespace Isolation Sandbox
# ==============================================================================
# This script executes arbitrary commands inside a hard memory cap and an isolated
# Linux user+pid+net namespace sandbox. It protects interactive desktop sessions
# from runaway memory allocation, swap thrashing, system freezes, and accidental
# process signaling (e.g. kill(-1) or killpg(1)).
#
# Primary Capabilities:
#   1. cgroup v2 Resource Limits:
#      - MemoryMax: Hard memory ceiling (default 3G, configurable via ETHAN_CAP).
#      - MemorySwapMax: Explicitly 0 to prevent swap thrashing and disk I/O lockup.
#      - CPUQuota: Restricts CPU consumption (default 400% = 4 cores, ETHAN_CPU).
#      - systemd-oomd integration: Proactive memory pressure termination.
#   2. Namespace Sandboxing (rootless unshare):
#      - user namespace: Unprivileged mapping of host UID to root in the sandbox.
#      - pid namespace: Private PID space where bash is PID 1, preventing signal
#        leakage (kill(-1) cannot escape the sandbox).
#      - net namespace: Network isolation with loopback up (127.0.0.1 bound).
#      - mount-proc: Fresh isolated /proc virtual filesystem.
#   3. PID 1 Zombie Reaping:
#      - The subshell remains PID 1 inside the namespace to adopt and reap
#        orphaned grandchildren, preventing zombie process buildup (<defunct>).
#   4. Process Priority & OOM Adjustment:
#      - Sets /proc/self/oom_score_adj to 500 so the kernel sacrifices this
#        sandbox first under memory pressure before touching desktop sessions.
#   5. Thermal Hysteresis Gating & Concurrency Slots:
#      - Delays execution if GPU/chassis temperature exceeds threshold (88°C).
#      - Non-blocking flock slots limit concurrent heavyweight executions.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Shell Safety Flags
# ------------------------------------------------------------------------------
# -e: Exit immediately if any command exits with a non-zero exit status.
# -u: Treat unset variables and parameters as errors during expansion.
# -o pipefail: Return the exit status of the last command in the pipeline that
#              failed, preventing masked pipeline errors.
set -euo pipefail

# Require at least one argument representing the target executable to run.
# Exits with status code 2 on invalid usage.
[ "$#" -ge 1 ] || { echo "usage: $0 <command...>" >&2; exit 2; }

# ------------------------------------------------------------------------------
# 2. Operating System Dispatch (macOS Compatibility)
# ------------------------------------------------------------------------------
# If running on macOS (Darwin), delegate to the Darwin Seatbelt sandbox runner.
if [ "$(uname -s)" = "Darwin" ]; then
  exec python3 "$(cd "$(dirname "$0")" && pwd)/ethan_mac_capped_run.py" "$@"
fi

# ------------------------------------------------------------------------------
# 3. PID 1 Execution & Zombie Reaping Architecture
# ------------------------------------------------------------------------------
# In Linux kernel semantics, PID 1 inside a PID namespace is the designated init
# process. It has two critical responsibilities:
#   a) Adopt orphaned grandchild processes when their parent terminates.
#   b) Reap terminated adopted children via wait()/waitpid() to clear their
#      entries from the kernel process table.
#
# IMPORTANT: We deliberately do NOT use 'exec' to replace the subshell with "$@".
# If we used 'exec', the user command would become PID 1. Most application
# runtimes and test suites (e.g. Python, Node.js, git sub-invocations) do not
# implement an init-style SIGCHLD reaping loop. Unreaped orphans remain in the
# process table as '<defunct>' zombies until PID 1 exits. Accumulating thousands
# of zombie processes wastes kernel memory structures and causes /proc scans
# (e.g. 'ps' or 'pgrep') to consume excessive CPU and heat the CPU package.
#
# By keeping Bash as PID 1, Bash's internal job control automatically reaps
# orphaned children as they terminate.
#
# OOM Score Adjustment:
# Writing '500' to /proc/self/oom_score_adj elevates the process's OOM badness
# score (range -1000 to +1000). If the host kernel experiences extreme memory
# starvation, the kernel OOM killer will kill this sandboxed process tree first,
# safeguarding desktop compositors (Wayland/X11), systemd, and user shells.
inner='echo 500 > /proc/self/oom_score_adj 2>/dev/null || true; "$@"; exit $?'

# ------------------------------------------------------------------------------
# 4. Host Mode Escape Hatch vs. Namespace Sandboxing
# ------------------------------------------------------------------------------
# If ETHAN_HOST=1 is set in the environment, bypass the namespace sandbox.
# This is necessary when workloads require direct access to host hardware
# (e.g. local LLM servers needing CUDA GPU device nodes, Wayland display sockets,
# or host network interfaces).
if [ "${ETHAN_HOST:-0}" = "1" ]; then
  echo "ethan_capped_run: ETHAN_HOST=1, running on the host without the namespace sandbox" >&2
  prefix=()
else
  # Loopback Interface Initialization:
  # In a freshly created Linux network namespace (--net), all interfaces are
  # detached and the loopback interface 'lo' is in the DOWN state by default.
  # Running 'ip link set lo up' brings the loopback interface UP, allowing
  # sandboxed test suites to bind to 127.0.0.1 or ::1 for local TCP/HTTP mocks.
  # No external network interfaces (eth0, wlan0) are visible, completely blocking
  # outbound/inbound internet and LAN communication.
  inner='ip link set lo up 2>/dev/null || true; '"$inner"

  # Validate that unprivileged user and PID namespaces are supported on this host.
  # If namespaces are disabled or restricted by kernel sysctl (e.g. Debian/RHEL
  # unprivileged_userns_clone=0), fail closed unless ETHAN_HOST=1 is specified.
  unshare --user --map-root-user --pid --fork --net --mount-proc true 2>/dev/null || {
    echo "ethan_capped_run: namespace sandbox unavailable; refusing. Set ETHAN_HOST=1 to run on the host." >&2; exit 3; }

  # Ephemeral Sandbox Home Directory:
  # Create a dedicated temporary directory to serve as $HOME for the sandbox.
  # This prevents untrusted commands or test runs from mutating real dotfiles,
  # caches, or configuration under /home/$USER.
  home="$(mktemp -d /tmp/ethan-sandbox-home.XXXXXX)"

  # Detailed Breakdown of 'unshare' Namespace Arguments:
  #   --user:
  #     Creates a new user namespace. Allows an unprivileged user to obtain
  #     full root privileges strictly inside this new namespace without sudo.
  #   --map-root-user:
  #     Maps the caller's host UID/GID to UID 0 (root) and GID 0 inside the
  #     user namespace. Necessary for mounting private procfs and configuring 'lo'.
  #   --pid:
  #     Creates a new PID namespace. Host processes are completely hidden.
  #     Processes inside the namespace cannot inspect, trace, or signal host tasks.
  #   --fork:
  #     Forks the specified command as a child of the unshare process.
  #     In Linux, a process cannot enter its own newly created PID namespace;
  #     only its child processes are placed inside the new namespace.
  #   --net:
  #     Creates an isolated network namespace with an independent network stack.
  #     Host network devices, routing tables, and firewall rules are unlinked.
  #   --mount-proc:
  #     Mounts a fresh, private instance of the /proc filesystem matching the
  #     new PID namespace. Prevents reading host process info via /proc.
  #
  # Environment Sanitization ('env -i'):
  #   Wipes ambient environment variables to avoid credential leakage, while
  #   preserving a minimal, controlled set of variables: PATH, HOME, LANG,
  #   PYTHONPATH, and required workspace tokens.
  prefix=(unshare --user --map-root-user --pid --fork --net --mount-proc
          env -i PATH=/usr/bin:/bin ETHAN_CAPPED_INNER=1 "HOME=$home" "LANG=${LANG:-C.UTF-8}" ${PYTHONPATH:+"PYTHONPATH=$PYTHONPATH"}
          ${TWU_DASHBOARD_RELEASE:+"TWU_DASHBOARD_RELEASE=$TWU_DASHBOARD_RELEASE"}
          ${TWU_DASHBOARD_WORKSPACE:+"TWU_DASHBOARD_WORKSPACE=$TWU_DASHBOARD_WORKSPACE"}
          ${TWU_ROOT:+"TWU_ROOT=$TWU_ROOT"})
fi

# ------------------------------------------------------------------------------
# 5. Thermal Hysteresis Gating
# ------------------------------------------------------------------------------
# Modern high-performance laptops share a unified cooling heatpipe assembly
# between CPU and discrete GPU. Heavy multi-threaded CPU tasks (e.g. test suites
# or compilation) elevate the temperature of the entire chassis, pushing the GPU
# toward critical thermal limits.
#
# To avoid cascading thermal throttling or tripping safety guards:
#   - Check GPU temperature using nvidia-smi if available.
#   - If current temperature >= ETHAN_THERMAL_GATE (default 88°C), pause and
#     wait in 5-second increments (up to ETHAN_THERMAL_WAIT, default 120s)
#     for the cooling fans to shed accumulated heat.
#   - Fail-open design: if nvidia-smi is missing, query times out, or the wait
#     budget expires, proceed anyway rather than causing an unrecoverable hang.
if [ "${ETHAN_THERMAL_WAIT:-120}" != "0" ] && command -v nvidia-smi >/dev/null 2>&1; then
  twaited=0
  while :; do
    gt="$(timeout 3 nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9')"
    { [ -z "$gt" ] || [ "$gt" -lt "${ETHAN_THERMAL_GATE:-88}" ]; } && break
    [ "$twaited" -ge "${ETHAN_THERMAL_WAIT:-120}" ] && { echo "ethan_capped_run: GPU still ${gt} C after ${twaited}s, running anyway" >&2; break; }
    [ "$twaited" -eq 0 ] && echo "ethan_capped_run: GPU ${gt} C >= ${ETHAN_THERMAL_GATE:-88}, waiting for it to cool (ETHAN_THERMAL_WAIT=0 skips)" >&2
    sleep 5; twaited=$((twaited + 5))
  done
fi

# ------------------------------------------------------------------------------
# 6. Concurrency Slot Limiting via File Locking (flock)
# ------------------------------------------------------------------------------
# Uncontrolled concurrent test runs can spike system load, saturate CPU cache,
# and induce thermal throttling. We restrict parallel runs to ETHAN_SLOTS (default 2).
#
# Implementation details:
#   - Uses non-blocking kernel advisory file descriptor locks ('flock -n').
#   - Uses slot files in XDG_RUNTIME_DIR or /tmp.
#   - If all slots are busy, waits in 5-second polling intervals up to
#     ETHAN_SLOT_WAIT (default 1800s).
#   - When the slot is acquired, the lock file descriptor remains open and is
#     inherited by the command. When the command finishes or is killed, the
#     Linux kernel automatically closes the file descriptor and releases the lock.
if [ "${ETHAN_SLOTS:-2}" != "0" ]; then
  slot_dir="${ETHAN_SLOT_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ethan-capped-slots}"
  mkdir -p "$slot_dir" 2>/dev/null || true
  if [ ! -d "$slot_dir" ] || [ ! -w "$slot_dir" ]; then
    slot_dir="/tmp/ethan-capped-slots-${UID:-$(id -u)}"
    mkdir -p "$slot_dir" 2>/dev/null || true
  fi
  waited=0; got=0
  while :; do
    for i in $(seq 1 "${ETHAN_SLOTS:-2}"); do
      if { exec {slotfd}>"$slot_dir/slot$i"; } 2>/dev/null; then
        if flock -n "$slotfd" 2>/dev/null; then got=1; break 2; else exec {slotfd}>&-; fi
      fi
    done
    [ "$waited" -ge "${ETHAN_SLOT_WAIT:-1800}" ] && break
    [ "$waited" -eq 0 ] && echo "ethan_capped_run: all ${ETHAN_SLOTS:-2} run slots busy, waiting (limits heat); ETHAN_SLOTS=0 skips" >&2
    sleep 5; waited=$((waited + 5))
  done
  [ "$got" = "1" ] || echo "ethan_capped_run: waited ${waited}s for a slot, running anyway" >&2
fi

# ------------------------------------------------------------------------------
# 7. systemd cgroup v2 Resource Enforcement via systemd-run
# ------------------------------------------------------------------------------
# Verify if the user's systemd D-Bus socket is accessible.
# If present, dispatch the command inside a transient systemd scope unit.
#
# Detailed Breakdown of systemd-run Options and cgroup Properties:
#   --user:
#     Connects to the caller's systemd user manager instance (rootless).
#   --scope:
#     Runs the process in a transient scope unit rather than a background service.
#     The calling shell manages the lifecycle and inherits standard I/O directly.
#   --quiet:
#     Suppresses systemd's informational start/stop messages on stderr.
#   --collect:
#     Ensures systemd unloads and garbage-collects the transient unit metadata
#     immediately upon process exit.
#
# cgroup v2 Properties (-p):
#   MemoryMax=${ETHAN_CAP:-3G}:
#     Sets cgroup v2 'memory.max'. If the aggregate memory consumption of all
#     processes in this scope reaches this limit (default 3 GiB), the kernel
#     attempts page reclamation. If memory cannot be reclaimed, the kernel
#     OOM killer invokes SIGKILL on processes within the cgroup.
#   MemorySwapMax=0:
#     Sets cgroup v2 'memory.swap.max' to zero. FORBIDS the sandboxed processes
#     from using swap space. When memory is exhausted, the process is terminated
#     immediately rather than writing dirty pages to disk, completely preventing
#     swap thrashing, saturated disk I/O queues, and catastrophic desktop UI freezes.
#   CPUQuota=${ETHAN_CPU:-400%}:
#     Sets cgroup v2 'cpu.max'. 400% grants 4 full CPU core equivalents of execution
#     time per period. Prevents test suites from saturating all available CPU
#     cores, preserving CPU cycles for responsive desktop compositor rendering.
#   ManagedOOMMemoryPressure=kill:
#     Enables systemd-oomd memory pressure monitoring for this unit.
#   ManagedOOMMemoryPressureLimit=40%:
#     Instructs systemd-oomd to terminate the unit if PSI (Pressure Stall Information)
#     memory pressure exceeds 40% over the configured evaluation window, acting
#     proactively before thrashing causes lockups.
if [ -S "${XDG_RUNTIME_DIR:-/run/user/${UID:-$(id -u)}}/bus" ]; then
  exec systemd-run --user --scope --quiet --collect \
    -p "MemoryMax=${ETHAN_CAP:-3G}" -p MemorySwapMax=0 -p "CPUQuota=${ETHAN_CPU:-400%}" \
    -p ManagedOOMMemoryPressure=kill -p ManagedOOMMemoryPressureLimit=40% \
    -- "${prefix[@]}" bash -c "$inner" _ "$@"
else
  # Fallback Execution:
  # If systemd user session is unavailable (e.g. minimal container environments),
  # execute directly inside the unshare namespace without cgroup properties.
  exec "${prefix[@]}" bash -c "$inner" _ "$@"
fi
