#!/system/bin/sh
# Phase 0 / step A: read-only inventory of the phone for the crosvm + drm2kgsl bring-up.
# Changes nothing. Run as root from Termux:
#   su -c 'sh /data/data/com.termux/files/home/phase0/host/00-inventory.sh'
# Writes the report to /sdcard/Download/phase0-inventory.txt and prints it.

APP=/data/data/cn.classfun.droidvm
OUT=/sdcard/Download/phase0-inventory.txt

# sha256 of the binaries in Droid-VM/DroidVM-Prebuilts @ c4998e1 (the prebuilts the dev build
# 0.0.6.r240.5c89691 and this fork's master ship). A mismatch means the installed app carries
# different binaries and the rest of the Phase 0 guide may not apply as written.
EXPECT="
cd3693ba876720f7ab7c08e5d6358101336f3bbcdb3d7d4f324ac29274bf6a7b usr/bin/crosvm
40b5edaa7c722b801b2b08d2f2d64fd55e56bebf62baec2dbb17e662a49f633d usr/lib/libvirglrenderer.so
aed0424b7c26f02d1fb94ea4db6bff2026ce05bf5ce0c8dcca6036531970cca5 usr/lib/librutabaga_gfx_ffi.so
ed5395e443fb2b3f71f647e80e6f434e93b342b463ce841c9319903affedbf52 usr/lib/libgfxstream_backend.so
829655e69d4620c2caaf737ccc3ea08afe1cc3d450b42460ac4a2a3ab7bd9abf usr/lib/libvulkan_freedreno.so
21b9749d87541200d805473cc3257eb98801e9882228e9d64ecdeaf16ecef227 usr/share/droidvm/edk2-gunyah.fd
"

{
echo "=== phase0 inventory $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "--- whoami: $(id)"

echo "--- phone"
echo "model=$(getprop ro.product.model) device=$(getprop ro.product.device) soc=$(getprop ro.soc.model) android=$(getprop ro.build.version.release) sdk=$(getprop ro.build.version.sdk)"
echo "kernel=$(uname -r)"
grep -m1 MemTotal /proc/meminfo
grep -m1 MemAvailable /proc/meminfo
df -h /data 2>/dev/null | tail -1

echo "--- DroidVM app"
dumpsys package cn.classfun.droidvm 2>/dev/null | grep -m3 -E 'versionName|versionCode|lastUpdateTime'

echo "--- device nodes"
for n in /dev/gunyah /dev/kgsl-3d0 /dev/udmabuf /dev/dma_heap/system; do
  if [ -e "$n" ]; then echo "present  $n"; else echo "MISSING  $n"; fi
done

echo "--- loaded kernel modules (gunyah / udmabuf / hugepage / nproc)"
lsmod 2>/dev/null | grep -iE 'gunyah|gh_|udmabuf|hugepage|nproc' || echo "(none of them loaded -- open the DroidVM app once; its daemon loads them)"
echo "udmabuf size_limit_mb=$(cat /sys/module/udmabuf/parameters/size_limit_mb 2>/dev/null || echo n/a)"

echo "--- gh_hugepage_reserve pool (guest RAM comes from here; pool_* counts are 2 MB pages)"
P=/sys/module/gh_hugepage_reserve/parameters
for f in system_reserve_mb system_reserve_mb_default pool_want pool_want_with_cma; do
  [ -r "$P/$f" ] && echo "$f=$(cat "$P/$f")"
done
[ -r "$P/refill_stat" ] && cat "$P/refill_stat"

echo "--- KernelSU modules"
for d in /data/adb/modules/*/; do
  [ -f "$d/module.prop" ] || continue
  id=$(grep -m1 '^id=' "$d/module.prop" | cut -d= -f2)
  ver=$(grep -m1 '^version=' "$d/module.prop" | cut -d= -f2)
  dis=""; [ -f "$d/disable" ] && dis=" (DISABLED)"
  echo "$id $ver mtime=$(stat -c %y "$d/module.prop" 2>/dev/null | cut -d. -f1)$dis"
done

echo "--- app prebuilts vs Droid-VM/DroidVM-Prebuilts c4998e1"
echo "$EXPECT" | while read -r sum rel; do
  [ -n "$rel" ] || continue
  f="$APP/$rel"
  if [ ! -f "$f" ]; then echo "MISSING  $rel"; continue; fi
  got=$(sha256sum "$f" | cut -d' ' -f1)
  if [ "$got" = "$sum" ]; then echo "match    $rel"; else echo "DIFFERS  $rel ($got)"; fi
done

echo "--- drm2kgsl capability markers in the installed binaries"
echo "crosvm Drm2KgslPool refs:        $(grep -c Drm2KgslPool "$APP/usr/bin/crosvm" 2>/dev/null)"
echo "crosvm gpu-guest-mb refs:        $(grep -c gpu-guest-mb "$APP/usr/bin/crosvm" 2>/dev/null)"
echo "virglrenderer /dev/kgsl-3d0 refs: $(grep -c kgsl-3d0 "$APP/usr/lib/libvirglrenderer.so" 2>/dev/null)"
echo "virglrenderer guest-alloc refs:   $(grep -c MSM_BO_GUEST_ALLOC "$APP/usr/lib/libvirglrenderer.so" 2>/dev/null)"

echo "--- host module set shipped for this kernel"
ls "$APP/usr/lib/modules/" 2>/dev/null

echo "--- display refresh (guest vblank follows the panel; 60 Hz caps GPU throughput)"
dumpsys display 2>/dev/null | grep -m4 -oE 'renderFrameRate [0-9.]+|refreshRate=[0-9.]+|mActiveSfDisplayMode[^,]*'

echo "--- running VMs"
ps -A 2>/dev/null | grep -E 'crosvm|qemu-system' || echo "(none)"

echo "--- existing VM files"
ls -la /storage/emulated/0/DroidVM/ 2>/dev/null
echo "=== end"
} 2>&1 | tee "$OUT"
echo
echo "saved to $OUT"
