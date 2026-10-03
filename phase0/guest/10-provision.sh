#!/bin/bash
# Phase 0 / step E: provision the Ubuntu 26.04 guest for the drm2kgsl route.
# Run inside the guest as root (over SSH or the serial console):
#   sudo bash 10-provision.sh [kde|none]
#
# Installs, pinned to the published DroidVM "droidvm" release line so guest and host match:
#   - droidvm-guest-additions v0.1.0 (DKMS gunyah_guest.ko + patched virtio-gpu, kernel 7.x)
#   - mesa-guest 26.3.0-devel+droidvm.r227672 (Turnip over virtio incl. Adreno 840 ids,
#     plus the Venus and gfxstream ICDs), from ferls2077/mesa-cross release "droidvm"
#   - a desktop (KDE Plasma by default, matching DroidVM's acceptance image)
# Then points Vulkan at Turnip and GL at zink. A reboot is required afterwards: the patched
# virtio-gpu only takes over from the initramfs on the next boot.
set -euo pipefail

DESKTOP=${1:-kde}
GA_REF=${GA_REF:-v0.1.0}   # use wip/3d-accel instead if the guest kernel is 7.1+
MESA_URL=${MESA_URL:-https://github.com/ferls2077/mesa-cross/releases/download/droidvm/mesa-guest_26.3.0-devel%2Bdroidvm.r227672.gcecc0e96_arm64.deb}

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
msg() { printf '\n== %s\n' "$*"; }

msg "preflight"
k=$(uname -r)
echo "kernel $k"
case "$k" in
  7.0.*) ;;
  7.*) echo "kernel is newer than 7.0; if the DKMS build fails, re-run with GA_REF=wip/3d-accel" ;;
  *) echo "kernel $k is not 7.x -- the guest additions only build for 7.x"; exit 1 ;;
esac
if dmesg | grep -q 'restricted DMA pool'; then
  dmesg | grep -m1 'restricted DMA pool'
else
  echo "WARNING: no 'restricted DMA pool' line in dmesg -- virtio DMA in a protected VM needs it"
fi
getent hosts ports.ubuntu.com >/dev/null || { echo "no DNS/network"; exit 1; }

msg "base packages"
apt-get update -qq
apt-get install -y -qq curl vulkan-tools mesa-utils alsa-utils pciutils

msg "guest additions ($GA_REF) + mesa-guest"
curl -fsSL "https://raw.githubusercontent.com/Droid-VM/droidvm-guest-additions/$GA_REF/install.sh" -o /tmp/ga-install.sh
DROIDVM_GA_REF="$GA_REF" DROIDVM_MESA_URL="$MESA_URL" bash /tmp/ga-install.sh

msg "Vulkan -> Turnip (drm2kgsl), GL -> zink"
icd=/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json
[ -f "$icd" ] || { echo "missing $icd -- mesa-guest did not install"; exit 1; }
sed -i '/^VK_DRIVER_FILES=/d; /^MESA_LOADER_DRIVER_OVERRIDE=/d' /etc/environment
printf 'VK_DRIVER_FILES=%s\nMESA_LOADER_DRIVER_OVERRIDE=zink\n' "$icd" >> /etc/environment
cat /etc/environment

case "$DESKTOP" in
  kde)
    msg "desktop: KDE Plasma + SDDM"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq kde-plasma-desktop sddm
    systemctl set-default graphical.target
    ;;
  none) msg "desktop: skipped" ;;
  *) echo "unknown desktop '$DESKTOP' (kde|none)"; exit 1 ;;
esac

msg "done -- reboot now (systemctl reboot), then run 20-check.sh"
dkms status
