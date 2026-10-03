#!/data/data/com.termux/files/usr/bin/bash
# Phase 0 / step C: build the Ubuntu 26.04 guest disk and a cloud-init seed disk, in Termux
# (as the normal Termux user, not root).
#
#   pkg install -y curl qemu-utils dosfstools mtools openssh
#   bash ~/phase0/host/02-make-image.sh <username> <password> [disk-size, default 64G]
#
# Outputs, in /storage/emulated/0/DroidVM/Ubuntu-26.04/:
#   resolute-server-cloudimg-arm64.qcow2  the guest disk, grown to the requested size
#   seed-cidata.img                       a 2 MB FAT disk labelled CIDATA (cloud-init NoCloud)
# Attach BOTH to the VM in DroidVM (seed as the second disk). On first boot cloud-init creates
# the user, sets the password, installs your SSH key and grows the root filesystem; no cloud
# metadata probing happens because NoCloud finds its data on the seed disk.
set -euo pipefail

user=${1:?usage: $0 <username> <password> [size]}
pass=${2:?usage: $0 <username> <password> [size]}
size=${3:-64G}

URL=https://cloud-images.ubuntu.com/resolute/current
IMG=resolute-server-cloudimg-arm64.img
DEST=/storage/emulated/0/DroidVM/Ubuntu-26.04
WORK=$HOME/phase0-image
mkdir -p "$WORK" "$DEST"
cd "$WORK"

for t in curl qemu-img mkfs.vfat mcopy sha256sum; do
  command -v $t >/dev/null || { echo "missing $t: pkg install -y curl qemu-utils dosfstools mtools"; exit 1; }
done

echo "== download $IMG"
curl -fL -C - -o "$IMG" "$URL/$IMG"
curl -fsSL -o SHA256SUMS "$URL/SHA256SUMS"
want=$(grep " \*$IMG\$" SHA256SUMS | cut -d' ' -f1)
got=$(sha256sum "$IMG" | cut -d' ' -f1)
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "checksum mismatch: want $want got $got"; exit 1; }
echo "checksum ok ($got)"

echo "== guest disk ($size)"
qemu-img info "$IMG" | grep -E 'file format|virtual size'
# Ubuntu ships the image with compressed qcow2 clusters, which crosvm cannot read. Rewrite it
# uncompressed (still qcow2, still sparse) so the app does not have to convert it at start.
qemu-img convert -p -O qcow2 "$IMG" "$DEST/resolute-server-cloudimg-arm64.qcow2"
qemu-img resize "$DEST/resolute-server-cloudimg-arm64.qcow2" "$size"
qemu-img info "$DEST/resolute-server-cloudimg-arm64.qcow2" | grep -E 'file format|virtual size'

echo "== cloud-init seed"
key=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  [ -f "$k" ] && { key=$(cat "$k"); break; }
done
if [ -z "$key" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
  key=$(cat "$HOME/.ssh/id_ed25519.pub")
fi

cat > meta-data <<EOF
instance-id: droidvm-ubuntu2604-1
local-hostname: ubuntu-dvm
EOF

cat > user-data <<EOF
#cloud-config
hostname: ubuntu-dvm
ssh_pwauth: true
users:
  - name: $user
    groups: [sudo, adm, video, render, audio, input]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    ssh_authorized_keys:
      - $key
chpasswd:
  expire: false
  users:
    - name: $user
      password: $pass
      type: text
growpart:
  mode: auto
  devices: ["/"]
EOF

rm -f seed-cidata.img
dd if=/dev/zero of=seed-cidata.img bs=1M count=2 status=none
mkfs.vfat -n CIDATA seed-cidata.img >/dev/null
mcopy -i seed-cidata.img user-data meta-data ::
mdir -i seed-cidata.img ::
cp seed-cidata.img "$DEST/seed-cidata.img"
rm -f user-data   # holds the password in plain text

ls -la "$DEST"
echo "done. SSH key used: ${key%% *} ...${key: -20}"
