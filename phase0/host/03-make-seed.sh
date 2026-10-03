#!/data/data/com.termux/files/usr/bin/bash
# Phase 0: (re)build only the cloud-init NoCloud seed disk, in Termux (normal user).
#
#   pkg install -y dosfstools mtools openssh
#   bash ~/phase0/host/03-make-seed.sh <username> <password>
#
# Every run uses a new instance-id, so on the next boot cloud-init treats the VM as a new
# instance and re-applies the user, password and SSH key (it also regenerates the SSH host
# keys; nothing else on the disk is touched). Use it to reset a password you can't log in with.
# Stop the VM first; the seed is read at boot.
set -euo pipefail

user=${1:?usage: $0 <username> <password>}
pass=${2:?usage: $0 <username> <password>}
DEST=/storage/emulated/0/DroidVM/Ubuntu-26.04
WORK=$HOME/phase0-image
mkdir -p "$WORK" "$DEST"
cd "$WORK"
for t in mkfs.vfat mcopy mdir ssh-keygen; do
  command -v $t >/dev/null || { echo "missing $t: pkg install -y dosfstools mtools openssh"; exit 1; }
done
case "$pass" in
  *[!A-Za-z0-9]*) echo "note: the password has symbols; if logging in on the native display fails, use letters and digits only (the on-screen keyboard mapping can drop symbols)";;
esac

key=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  [ -f "$k" ] && { key=$(cat "$k"); break; }
done
if [ -z "$key" ]; then
  ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
  key=$(cat "$HOME/.ssh/id_ed25519.pub")
fi

cat > meta-data <<EOF
instance-id: droidvm-ubuntu2604-$(date +%Y%m%d%H%M%S)
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
