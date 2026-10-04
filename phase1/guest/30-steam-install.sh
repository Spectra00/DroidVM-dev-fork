#!/bin/bash
# Phase 1 / step A: install Valve's native ARM64 Steam client in the Ubuntu 26.04 guest, keeping
# the drm2kgsl Turnip driver from Phase 0 as the only Vulkan driver it sees.
# Run inside the guest as the desktop user (not root; it calls sudo for packages):
#   bash 30-steam-install.sh
#
# What it does, and why:
# - No snap and no Ubuntu "steam" package: the snap ships its own Mesa, and the x86 package wants
#   i386 multiarch. Both would route around the guest's Turnip.
# - Takes Valve's linuxarm64 client from Valve's update manifest and checks it against the sha256
#   in that manifest. The archive uses backslash path separators, so it is unpacked with Python
#   (plain unzip would create file names containing backslashes).
# - Windows games run through Valve's Proton ARM64 (Wine ARM64EC + FEX for the x86 parts), which
#   the client downloads itself and which calls the system Vulkan driver directly. No FEX
#   packages are needed for that. x86 Linux games (Valve's FEX tool) are a later step.
# - Writes a launcher, ~/.local/bin/steam-arm64, and a menu entry.
# Based on the procedures in Scrumpper/Steam-ARM and UbuntuAsahi/steam-arm64; Asahi's muvm is
# not needed here because this guest kernel uses 4K pages.
set -euo pipefail

S=$HOME/.local/share/Steam
D=$S/steamrtarm64
CDN=https://client-update.steamstatic.com
ICD=/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json

say() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

say "checks"
[ "$(id -u)" != 0 ] || die "run as your desktop user, not root"
[ "$(uname -m)" = aarch64 ] || die "not an aarch64 system"
[ "$(getconf PAGESIZE)" = 4096 ] || die "page size $(getconf PAGESIZE); Proton/FEX need 4096"
[ -f "$ICD" ] || die "$ICD missing -- Phase 0 (10-provision.sh) not done"
grep -q "^VK_DRIVER_FILES=$ICD" /etc/environment || die "VK_DRIVER_FILES not set in /etc/environment -- Phase 0 not done"
pgrep -u "$(id -u)" -x steam >/dev/null && die "Steam is running; quit it first"
echo "ok: aarch64, 4K pages, Turnip ICD present"

say "packages"
sudo apt-get update
sudo apt-get install -y curl python3 file bubblewrap dbus-daemon xz-utils zenity \
  libsdl3-0 libgtk2.0-0t64 libopenal1 libvulkan1 vulkan-tools mesa-utils
# The client links libvpx.so.6; Ubuntu ships a newer soname. Install the current one and alias it.
vpx=$(apt-cache search --names-only '^libvpx[0-9]+$' | cut -d' ' -f1 | sort -V | tail -1)
[ -n "$vpx" ] && sudo apt-get install -y "$vpx"
L=/usr/lib/aarch64-linux-gnu
if [ ! -e $L/libvpx.so.6 ]; then
  newest=$(ls $L/libvpx.so.[0-9]* 2>/dev/null | grep -E 'libvpx\.so\.[0-9]+$' | sort -V | tail -1 || true)
  [ -n "$newest" ] && sudo ln -s "$newest" $L/libvpx.so.6 && echo "libvpx.so.6 -> $newest"
fi
echo "vm.max_map_count=$(sysctl -n vm.max_map_count)"
[ "$(sysctl -n vm.max_map_count)" -ge 1048576 ] || {
  echo 'vm.max_map_count = 1048576' | sudo tee /etc/sysctl.d/80-steam.conf >/dev/null
  sudo sysctl -q -p /etc/sysctl.d/80-steam.conf; }

say "Steam client (linuxarm64)"
mkdir -p "$S"
if [ -x "$D/steam" ] && file -b "$D/steam" | grep -q aarch64; then
  echo "client already present; keeping it (it updates itself)"
else
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  entry=""
  for ch in steam_client_linuxarm64 steam_client_publicbeta_linuxarm64; do
    curl -fsSL -o "$T/manifest" "$CDN/$ch" || continue
    entry=$(grep -aoE 'bins_linuxarm64_linuxarm64\.zip\.[0-9a-f]+' "$T/manifest" | head -1 || true)
    [ -n "$entry" ] && { echo "channel $ch"; break; }
  done
  [ -n "$entry" ] || die "no linuxarm64 package in Valve's manifests (check network: curl -I $CDN)"
  sha2=$(awk '/"bins_linuxarm64_linuxarm64"/ {b=1} b && $1=="\"sha2\"" {gsub(/"/,"",$2); print $2; exit} b && /^[[:space:]]*}/ {exit}' "$T/manifest")
  echo "package $entry"
  curl -fL -o "$T/client.zip" "$CDN/$entry"
  if [ "${#sha2}" = 64 ]; then got=$(sha256sum "$T/client.zip" | cut -c1-64); want=$sha2
  else got=$(sha1sum "$T/client.zip" | cut -c1-40); want=${entry##*.}; fi
  [ "$got" = "$want" ] || die "checksum mismatch (got $got, want $want); run again"
  echo "checksum ok"
  python3 - "$T/client.zip" "$T/x" <<'PY'
import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1]); root = sys.argv[2]; n = 0
for i in z.infolist():
    name = i.filename.replace("\\", "/")
    if name.endswith("/") or name.startswith("/") or ".." in name.split("/"): continue
    dst = os.path.join(root, name); os.makedirs(os.path.dirname(dst), exist_ok=True)
    with z.open(i) as src, open(dst, "wb") as out: out.write(src.read())
    mode = i.external_attr >> 16
    if mode: os.chmod(dst, mode & 0o755)
    n += 1
print("extracted %d files" % n)
PY
  find "$T/x" -type f -exec sh -c 'for f; do file -b "$f" | grep -qE "executable|shell script" && chmod 755 "$f"; done; true' sh {} +
  [ -x "$T/x/steamrtarm64/steam" ] || die "steamrtarm64/steam missing after unpacking (package layout changed?)"
  rm -rf "$D"; mv "$T/x/steamrtarm64" "$D"
fi
mkdir -p "$HOME/.steam" "$HOME/.config/openvr"
ln -sfn "$S" "$HOME/.steam/steam"
ln -sfn "$S" "$HOME/.steam/root"

say "launcher ~/.local/bin/steam-arm64"
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"
cat > "$HOME/.local/bin/steam-arm64" <<'LAUNCH'
#!/bin/bash
# Starts Valve's ARM64 Steam client on the guest's Turnip (drm2kgsl) Vulkan driver.
# Output goes to ~/steam-arm64.log.
S=$HOME/.local/share/Steam; D=$S/steamrtarm64
exec >>"$HOME/steam-arm64.log" 2>&1
echo "=== steam-arm64 start $(date -Is)"
# Same driver selection as the desktop (from /etc/environment); restated in case the client is
# started from a shell that did not read it.
export VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json
export MESA_LOADER_DRIVER_OVERRIDE=zink
# The overlay UI crashes without the client folder on the library path.
export LD_LIBRARY_PATH="$D${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Steam's ARM64 pipeline-cache layer stops Proton games at Vulkan device creation.
export DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1
# Shader pre-caching off unless STEAM_SHADERS=1 (large downloads, long fossilize runs).
[ "${STEAM_SHADERS:-0}" = 1 ] && NOSHADERS= || NOSHADERS=-noshaders
cd "$D" || exit 1
# First start verifies files, fetches the rest of the client and the SDK folder, then exits.
if [ ! -f "$S/linuxarm64/steamclient.so" ]; then
  ./steam "$@"
  [ -f "$S/linuxarm64/steamclient.so" ] || { echo "first start did not finish"; exit 1; }
  ln -sfn "$S/linuxarm64" "$HOME/.steam/sdkarm64"
fi
# The client exits with 42 after applying its own update; start it again (at most twice).
for try in 1 2 3; do
  ./steam -noverifyfiles -norepairfiles $NOSHADERS "$@"; rc=$?
  echo "=== steam exit $rc (try $try)"
  [ "$rc" = 42 ] || exit $rc
done
LAUNCH
chmod +x "$HOME/.local/bin/steam-arm64"
cat > "$HOME/.local/share/applications/steam-arm64.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Steam (ARM64)
Exec=$HOME/.local/bin/steam-arm64 %U
Icon=steam
Terminal=false
Categories=Game;
MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;
DESK
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
# Game shortcuts Steam creates run "steam steam://rungameid/<id>"; give them a "steam" on the
# default PATH (they go through the running client, so per-game launch options still apply).
sudo ln -sfn "$HOME/.local/bin/steam-arm64" /usr/local/bin/steam

say "done"
echo "Start it from the menu (Games > Steam (ARM64)) or a terminal in the Plasma session:"
echo "  ~/.local/bin/steam-arm64 &   then   tail -f ~/steam-arm64.log"
echo "The first start downloads the rest of the client and may restart itself once or twice."
