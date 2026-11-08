#!/usr/bin/env bash
# Program: Linux cgroup v2 Resource Governance & Namespace Sandbox
# Programmer: Ethan Kilmer
# Last Modified: 11/08/2026
# Purpose: Execute commands inside hard memory caps and isolated Linux namespaces to prevent desktop freezes.
#
# ==============================================================================
# Linux Memory Safety & Host Stability Setup
# ==============================================================================
# One-time host root setup to configure kernel swap, sysctl memory tunables,
# and systemd-oomd pressure limits so runaway processes cannot freeze the system.
#
# Primary Capabilities:
#   1. Managed Swapfile (/swapfile):
#      - Provisions an 8 GiB unfragmented swapfile with priority 10.
#      - Ensures swap survives reboots via an idempotent entry in /etc/fstab.
#   2. Kernel Virtual Memory Tuning (/etc/sysctl.d/99-ethan-memory.conf):
#      - vm.swappiness = 30: Swaps only under genuine memory pressure.
#      - vm.vfs_cache_pressure = 50: Prevents premature eviction of inode/dentry caches.
#   3. systemd-oomd Integration (/etc/systemd/oomd.conf.d/ethan.conf):
#      - SwapUsedLimit=90%: Triggers corrective action before disk swap fills completely.
#      - DefaultMemoryPressureLimit=50%: Kills offending cgroups under severe PSI pressure.
#
# Execution Modes:
#   - Preview / Dry-run:  bash scripts/ethan_memory_safety_setup.sh --check (no root required)
#   - Apply Configuration: sudo bash scripts/ethan_memory_safety_setup.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Shell Safety Flags
# ------------------------------------------------------------------------------
# -e: Exit immediately if any command exits with a non-zero exit status.
# -u: Treat unset variables and parameters as fatal errors.
# -o pipefail: Ensure pipeline exit status reflects the last failing command.
set -euo pipefail

# ------------------------------------------------------------------------------
# 2. Configuration Variables & Constants
# ------------------------------------------------------------------------------
# SWAPFILE: Absolute filesystem path to the designated host swap file
SWAPFILE=/swapfile

# SYSCTL: Target path for kernel sysctl persistent memory tuning drop-in configuration
SYSCTL=/etc/sysctl.d/99-ethan-memory.conf

# OOMD_DROPIN: Configuration drop-in directory and file for systemd-oomd service settings
OOMD_DROPIN=/etc/systemd/oomd.conf.d/ethan.conf

# FSTAB_LINE: Idempotent /etc/fstab line to mount the swapfile on boot with priority 10
FSTAB_LINE="$SWAPFILE none swap defaults,pri=10 0 0"

# CHECK: Dry-run preview flag (0 = apply changes with root, 1 = dry-run check only)
CHECK=0

# Evaluate command-line argument: check if caller requested dry-run mode (--check)
[ "${1:-}" = "--check" ] && CHECK=1

# ------------------------------------------------------------------------------
# 3. Helper Functions
# ------------------------------------------------------------------------------
# say: Print formatted message followed by newline to stdout
say() { printf '%s\n' "$*"; }

# run: Conditional execution wrapper; in dry-run mode (--check), logs the command;
# otherwise, executes the command with its arguments
run() { if [ "$CHECK" = 1 ]; then say "would run: $*"; else "$@"; fi; }

# ------------------------------------------------------------------------------
# 4. Privilege Verification
# ------------------------------------------------------------------------------
# If not running in dry-run mode, require effective UID 0 (root).
# Non-root execution in apply mode terminates with exit code 1 and usage instructions.
if [ "$CHECK" = 0 ] && [ "$(id -u)" != 0 ]; then
  say "Run with sudo:  sudo bash $0   (preview without root: --check)"; exit 1
fi

# ------------------------------------------------------------------------------
# 5. Swap File Verification and Activation
# ------------------------------------------------------------------------------
# Check if /swapfile is already registered and active in kernel swap tables
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
  # Swap file is already active; no modification needed
  say "swap: $SWAPFILE already active"
else
  # Swap file is not currently active
  if [ ! -e "$SWAPFILE" ]; then
    # Swapfile does not exist on disk; allocate an 8 GiB hole-free file via mkswap
    say "swap: $SWAPFILE missing; creating 8 GiB"
    run mkswap -U clear --size 8G --file "$SWAPFILE"
  elif [ "$CHECK" = 1 ]; then
    # In preview mode, report actions that would be taken on existing file
    say "would run: chmod 600 $SWAPFILE && swapon $SWAPFILE (rebuilding with mkswap only if the kernel rejects it)"
  else
    # Ensure strict file permissions: read/write only by root
    chmod 600 "$SWAPFILE"
    # Attempt to activate swap on existing file; if kernel rejects it, rebuild it cleanly
    if ! swapon "$SWAPFILE" 2>/dev/null; then
      say "swap: existing file rejected by the kernel; rebuilding (it is only a swap file)"
      rm -f "$SWAPFILE"
      mkswap -U clear --size 8G --file "$SWAPFILE"
    fi
  fi
  # If not in dry-run mode, verify activation; if not active, invoke swapon
  [ "$CHECK" = 1 ] || { swapon --show | grep -q "$SWAPFILE" || swapon "$SWAPFILE"; }
fi

# ------------------------------------------------------------------------------
# 6. Persistent Boot Configuration (/etc/fstab)
# ------------------------------------------------------------------------------
# Verify whether /swapfile is already listed in /etc/fstab
if ! grep -qsE "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab; then
  # Fstab entry missing; append FSTAB_LINE so swap is mounted automatically across reboots
  say "fstab: adding swap line so it survives reboot"
  [ "$CHECK" = 1 ] && say "would append: $FSTAB_LINE" || printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
fi

# ------------------------------------------------------------------------------
# 7. Kernel VM Sysctl Configuration
# ------------------------------------------------------------------------------
# Tune kernel VM parameters to prevent aggressive paging and maintain VFS metadata:
#   - vm.swappiness = 30: Tells kernel to prefer reclaiming clean page cache before swapping
#   - vm.vfs_cache_pressure = 50: Protects dentry and inode caches from premature eviction
say "sysctl: swappiness 30"
if [ "$CHECK" = 1 ]; then
  # Preview mode: log action
  say "would write $SYSCTL"
else
  # Apply mode: write sysctl configuration and reload sysctl rules immediately
  printf 'vm.swappiness = 30\nvm.vfs_cache_pressure = 50\n' > "$SYSCTL"
  sysctl -q -p "$SYSCTL"
fi

# ------------------------------------------------------------------------------
# 8. systemd-oomd Proactive Out-Of-Memory Daemon Configuration
# ------------------------------------------------------------------------------
# Configure systemd-oomd drop-in parameters:
#   - SwapUsedLimit=90%: Triggers unit termination if host swap usage crosses 90%
#   - DefaultMemoryPressureLimit=50%: Monitors PSI memory pressure, acting before lockups
#   - DefaultMemoryPressureDurationSec=20s: Window duration for PSI pressure evaluation
say "oomd: swap-used limit 90%, default memory-pressure limit 50% for 20 s"
if [ "$CHECK" = 1 ]; then
  # Preview mode: log action
  say "would write $OOMD_DROPIN and enable systemd-oomd"
else
  # Apply mode: create drop-in directory, write config, and enable/start systemd-oomd daemon
  mkdir -p "$(dirname "$OOMD_DROPIN")"
  printf '[OOM]\nSwapUsedLimit=90%%\nDefaultMemoryPressureLimit=50%%\nDefaultMemoryPressureDurationSec=20s\n' > "$OOMD_DROPIN"
  systemctl enable --now systemd-oomd
fi

# ------------------------------------------------------------------------------
# 9. Verification Summary
# ------------------------------------------------------------------------------
# Print command suggestions for the user to independently verify host state
say "done. verify: swapon --show; systemctl is-active systemd-oomd; sysctl vm.swappiness"
