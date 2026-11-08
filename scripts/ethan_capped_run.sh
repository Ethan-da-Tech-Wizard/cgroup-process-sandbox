#!/usr/bin/env bash
# Program: Linux cgroup v2 Resource Governance & Namespace Sandbox
# Programmer: Ethan Kilmer
# Last Modified: 11/08/2026
# Purpose: Execute commands inside hard memory caps and isolated Linux namespaces to prevent desktop freezes.
#
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
# -e: Exit immediately if any command returns a non-zero exit code.
# -u: Treat unset variables and parameters as errors during variable expansion.
# -o pipefail: Pipeline return code is the value of the last (rightmost) command
#              to exit with a non-zero status, preventing errors masked by pipes.
set -euo pipefail

# Argument count validation:
# Ensure the caller supplied at least one command argument to execute.
# If no argument is provided, emit usage syntax to stderr and exit with status 2.
[ "$#" -ge 1 ] || { echo "usage: $0 <command...>" >&2; exit 2; }

# ------------------------------------------------------------------------------
# 2. Operating System Dispatch (macOS Compatibility)
# ------------------------------------------------------------------------------
# Inspect kernel operating system name via 'uname -s'.
# If running on macOS (Darwin kernel), delegate execution to the Darwin Seatbelt
# runner script (ethan_mac_capped_run.py) located in the same directory.
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
# Evaluate ETHAN_HOST environment variable (default: 0).
# When ETHAN_HOST=1 is explicitly supplied, skip the unshare namespace sandbox.
# This mode is required for workloads needing host GPU device nodes (CUDA/DRI),
# direct host networking, or local graphical display server sockets (Wayland/X11).
if [ "${ETHAN_HOST:-0}" = "1" ]; then
  # Notify user on stderr that host mode is active and namespace sandbox is bypassed
  echo "ethan_capped_run: ETHAN_HOST=1, running on the host without the namespace sandbox" >&2
  # Initialize prefix array as empty so command runs directly in the current namespace
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
  # Runs a smoke test with unshare. If namespaces are disabled or restricted by
  # kernel sysctl (e.g. Debian/RHEL unprivileged_userns_clone=0), fail closed
  # with status code 3 unless ETHAN_HOST=1 is specified.
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
  # Track elapsed wait time in seconds
  twaited=0
  # Enter thermal polling loop
  while :; do
    # Query GPU temperature in Celsius, stripping all non-digits, with a 3-second timeout
    gt="$(timeout 3 nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -dc '0-9')"
    # Break immediately if temperature is unknown or below configured gate (default 88°C)
    { [ -z "$gt" ] || [ "$gt" -lt "${ETHAN_THERMAL_GATE:-88}" ]; } && break
    # Break if thermal wait budget (default 120s) has expired, logging fail-open warning
    [ "$twaited" -ge "${ETHAN_THERMAL_WAIT:-120}" ] && { echo "ethan_capped_run: GPU still ${gt} C after ${twaited}s, running anyway" >&2; break; }
    # Print initial notification to stderr on the first wait iteration
    [ "$twaited" -eq 0 ] && echo "ethan_capped_run: GPU ${gt} C >= ${ETHAN_THERMAL_GATE:-88}, waiting for it to cool (ETHAN_THERMAL_WAIT=0 skips)" >&2
    # Sleep 5 seconds between polls and increment elapsed wait counter
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
  # Determine primary runtime directory for slot lock files
  slot_dir="${ETHAN_SLOT_DIR:-${XDG_RUNTIME_DIR:-/tmp}/ethan-capped-slots}"
  mkdir -p "$slot_dir" 2>/dev/null || true
  # Fallback to /tmp with user UID if primary slot directory is unwritable or unavailable
  if [ ! -d "$slot_dir" ] || [ ! -w "$slot_dir" ]; then
    slot_dir="/tmp/ethan-capped-slots-${UID:-$(id -u)}"
    mkdir -p "$slot_dir" 2>/dev/null || true
  fi
  # Track elapsed time waiting for an open slot and lock acquisition status
  waited=0; got=0
  # Polling loop for non-blocking file descriptor locking
  while :; do
    # Iterate through slot indices 1..ETHAN_SLOTS
    for i in $(seq 1 "${ETHAN_SLOTS:-2}"); do
      # Dynamically open file descriptor {slotfd} pointing to slot file
      if { exec {slotfd}>"$slot_dir/slot$i"; } 2>/dev/null; then
        # Attempt non-blocking kernel advisory lock (-n)
        if flock -n "$slotfd" 2>/dev/null; then
          # Lock acquired successfully; break out of both loop levels
          got=1; break 2;
        else
          # Lock failed (slot in use); close file descriptor and check next slot
          exec {slotfd}>&-;
        fi
      fi
    done
    # Exit polling loop if slot wait budget (default 1800s) has been exceeded
    [ "$waited" -ge "${ETHAN_SLOT_WAIT:-1800}" ] && break
    # Emit waiting notification to stderr on the first retry iteration
    [ "$waited" -eq 0 ] && echo "ethan_capped_run: all ${ETHAN_SLOTS:-2} run slots busy, waiting (limits heat); ETHAN_SLOTS=0 skips" >&2
    # Sleep 5 seconds and increment elapsed counter
    sleep 5; waited=$((waited + 5))
  done
  # If slot wait timed out without lock, notify user and proceed fail-open
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
  # Execute via systemd-run in transient user scope with strict cgroup v2 parameters
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
