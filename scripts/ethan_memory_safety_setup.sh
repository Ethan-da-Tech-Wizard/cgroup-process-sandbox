#!/usr/bin/env bash
# One-time root setup so a runaway process cannot freeze this laptop (15.6 GB RAM, no swap).
# Ethan authorized swap + systemd-oomd on 2026-11-01. Run:  sudo bash scripts/ethan_memory_safety_setup.sh
# Read-only preview, no root needed:  bash scripts/ethan_memory_safety_setup.sh --check
# Idempotent. Touches: swap activation, one fstab line, one sysctl file, oomd settings. Nothing else.
set -euo pipefail

SWAPFILE=/swapfile
SYSCTL=/etc/sysctl.d/99-ethan-memory.conf
OOMD_DROPIN=/etc/systemd/oomd.conf.d/ethan.conf
FSTAB_LINE="$SWAPFILE none swap defaults,pri=10 0 0"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

say() { printf '%s\n' "$*"; }
run() { if [ "$CHECK" = 1 ]; then say "would run: $*"; else "$@"; fi; }

if [ "$CHECK" = 0 ] && [ "$(id -u)" != 0 ]; then
  say "Run with sudo:  sudo bash $0   (preview without root: --check)"; exit 1
fi

# 1. Swap: use the existing /swapfile if the kernel accepts it, otherwise rebuild it hole-free.
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
  say "swap: $SWAPFILE already active"
else
  if [ ! -e "$SWAPFILE" ]; then
    say "swap: $SWAPFILE missing; creating 8 GiB"; run mkswap -U clear --size 8G --file "$SWAPFILE"
  elif [ "$CHECK" = 1 ]; then
    say "would run: chmod 600 $SWAPFILE && swapon $SWAPFILE (rebuilding with mkswap only if the kernel rejects it)"
  else
    chmod 600 "$SWAPFILE"
    if ! swapon "$SWAPFILE" 2>/dev/null; then
      say "swap: existing file rejected by the kernel; rebuilding (it is only a swap file)"
      rm -f "$SWAPFILE"; mkswap -U clear --size 8G --file "$SWAPFILE"
    fi
  fi
  [ "$CHECK" = 1 ] || { swapon --show | grep -q "$SWAPFILE" || swapon "$SWAPFILE"; }
fi
if ! grep -qsE "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab; then
  say "fstab: adding swap line so it survives reboot"
  [ "$CHECK" = 1 ] && say "would append: $FSTAB_LINE" || printf '%s\n' "$FSTAB_LINE" >> /etc/fstab
fi

# 2. Kernel tuning: use swap only under real pressure; keep file cache from being evicted too eagerly.
say "sysctl: swappiness 30"
if [ "$CHECK" = 1 ]; then say "would write $SYSCTL"; else
  printf 'vm.swappiness = 30\nvm.vfs_cache_pressure = 50\n' > "$SYSCTL"; sysctl -q -p "$SYSCTL"
fi

# 3. systemd-oomd: acts only on units that opt in (the capped test runner and its slice), never on terminals.
say "oomd: swap-used limit 90%, default memory-pressure limit 50% for 20 s"
if [ "$CHECK" = 1 ]; then say "would write $OOMD_DROPIN and enable systemd-oomd"; else
  mkdir -p "$(dirname "$OOMD_DROPIN")"
  printf '[OOM]\nSwapUsedLimit=90%%\nDefaultMemoryPressureLimit=50%%\nDefaultMemoryPressureDurationSec=20s\n' > "$OOMD_DROPIN"
  systemctl enable --now systemd-oomd
fi

say "done. verify: swapon --show; systemctl is-active systemd-oomd; sysctl vm.swappiness"
