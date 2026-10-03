#!/bin/bash
# Phase 0 / step F: verify the drm2kgsl stack inside the guest after the post-provision reboot.
# Run inside the guest (as the desktop user, from a terminal in the graphical session for the
# Vulkan/GL lines to be meaningful):
#   bash 20-check.sh | tee ~/phase0-check.txt
# Prints PASS/FAIL per item; paste the whole output back.

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; }
info() { echo "info  $*"; }
dm() { sudo dmesg 2>/dev/null || dmesg; }

echo "=== phase0 guest check $(date -Is) kernel $(uname -r)"

dm | grep -q 'restricted DMA pool' && pass "restricted DMA pool: $(dm | grep -m1 -o 'restricted DMA pool.*')" \
  || fail "no restricted DMA pool line"

m=$(modinfo -n virtio_gpu 2>/dev/null)
case "$m" in
  */updates/dkms/*) pass "virtio_gpu from DKMS ($m)" ;;
  *) fail "virtio_gpu is the in-tree module ($m) -- guest additions not active (reboot? update-initramfs -u?)" ;;
esac
lsmod | grep -q '^gunyah_guest' && pass "gunyah_guest loaded" || fail "gunyah_guest not loaded"

if dm | grep -q 'has_create_guest_handle=1'; then pass "has_create_guest_handle=1"
else fail "has_create_guest_handle not 1 -- app needs udmabuf (guest-alloc) on and a VRAM size > 0"; fi
if dm | grep -q 'guest-alloc pool: base'; then pass "$(dm | grep -m1 -o 'guest-alloc pool: base.*')"
elif dm | grep -q 'guest-alloc: no pool in DT'; then fail "no guest pool in the DT (VRAM size 0, or the VM is not protected)"
else fail "no guest-alloc pool line"; fi
dm | grep -m1 -o 'host pool: .*' | sed 's/^/info  /'
n=$(dm | grep -c 'command 0x203')
[ "$n" = 0 ] && pass "no 'command 0x203' errors" || fail "$n 'command 0x203' errors"
dm | grep -iE 'virtio_gpu.*(error|fail)|lent memory' | head -5 | sed 's/^/info  /'

echo "--- Vulkan"
if command -v vulkaninfo >/dev/null; then
  vs=$(vulkaninfo --summary 2>&1)
  echo "$vs" | grep -E 'driverName|deviceName|apiVersion|driverInfo' | sed 's/^/info  /'
  echo "$vs" | grep -q 'driverName *= *turnip' && pass "Vulkan driver is turnip" || fail "Vulkan driver is not turnip"
  echo "$vs" | grep -q 'Adreno (TM) 840' && pass "device is Adreno 840" || fail "device is not Adreno 840"
else
  fail "vulkaninfo not installed (apt install vulkan-tools)"
fi

echo "--- GL"
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v glxinfo >/dev/null; then
  glxinfo -B 2>&1 | grep -E 'OpenGL renderer|OpenGL version' | sed 's/^/info  /'
  glxinfo -B 2>&1 | grep -q 'zink' && pass "GL renderer is zink" || fail "GL renderer is not zink"
else
  info "no graphical session in this shell -- skipped glxinfo"
fi

echo "--- audio"
if grep -q . /proc/asound/cards 2>/dev/null && ! grep -q 'no soundcards' /proc/asound/cards; then
  pass "sound card: $(head -1 /proc/asound/cards)"
else
  fail "no sound card"
fi

echo "--- memory / disk"
free -m | sed 's/^/info  /'
df -h / | tail -1 | sed 's/^/info  /'
echo "=== end"
