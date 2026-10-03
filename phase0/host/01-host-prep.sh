#!/system/bin/sh
# Phase 0 / step B: host preparation before starting the Ubuntu VM with drm2kgsl.
# Idempotent; safe to re-run after every phone reboot. Run as root:
#   su -c 'sh /data/data/com.termux/files/home/phase0/host/01-host-prep.sh'
#
# From Droid-VM/droidvm-meta-repo plans/CROSVM_3D_LAUNCH_REFERENCE.md and deploy/SETUP.md.
# Never kill -9 a running crosvm: it leaks RM memparcels until the phone reboots. Stop the
# guest with `systemctl poweroff` (or the app's power button), or `kill -TERM` as a last resort.

fail=0

# The DroidVM daemon loads these when the app UI is opened. Without them crosvm fails early
# (missing gunyah-host-share / gh-unmovable) or blob imports break (udmabuf).
for m in gunyah_host_share gh_unmovable udmabuf; do
  if lsmod | grep -q "^$m "; then
    echo "ok       module $m loaded"
  else
    echo "MISSING  module $m -- open the DroidVM app (its daemon loads it), then re-run"
    fail=1
  fi
done

# gh-hugepage-reserve (KernelSU module): builds older than 2026-08-08 caused Bad page state and
# kernel panics on VM teardown in DroidVM's testing. Report what is installed; can't verify the
# build date from here beyond the module.prop timestamp.
hp=$(grep -l -iE 'hugepage' /data/adb/modules/*/module.prop 2>/dev/null | head -1)
if [ -n "$hp" ]; then
  echo "info     $(grep -m1 '^id=' "$hp") $(grep -m1 '^version=' "$hp") installed $(stat -c %y "$hp" | cut -d. -f1)"
else
  echo "WARN     no gh-hugepage-reserve KernelSU module found (needed for --hugepages)"
fi

# Default udmabuf limit is 64 MB per handle; GPU blobs need far more.
if [ -w /sys/module/udmabuf/parameters/size_limit_mb ]; then
  echo 4096 > /sys/module/udmabuf/parameters/size_limit_mb
  echo "ok       udmabuf size_limit_mb=$(cat /sys/module/udmabuf/parameters/size_limit_mb)"
else
  echo "MISSING  /sys/module/udmabuf/parameters/size_limit_mb"
  fail=1
fi

# Give the hugepage/folio allocator contiguous memory to work with.
sync
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
echo 3 > /proc/sys/vm/drop_caches
echo "ok       page cache dropped, memory compacted"

# Only one crosvm at a time: two fight over the GPU pool and fail with ENOMEM.
if ps -A | grep -q '[c]rosvm'; then
  echo "WARN     a crosvm is already running -- stop that VM from its guest before starting another"
fi

grep -m1 MemAvailable /proc/meminfo
[ $fail = 0 ] && echo "host ready" || echo "host NOT ready (see MISSING lines)"
exit $fail
