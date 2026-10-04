#!/bin/bash
# Phase 1 / check: what Steam sees. Run inside the guest as the desktop user, from a terminal in
# the Plasma session, after Steam has started once (and again after a game has been launched):
#   bash 40-steam-check.sh | tee ~/phase1-check.txt
S=$HOME/.local/share/Steam
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; }; info() { echo "info  $*"; }

echo "=== phase1 steam check $(date -Is)"
[ -x "$S/steamrtarm64/steam" ] && pass "client: $(head -1 "$S/steamrtarm64/builddate.txt" 2>/dev/null | tr -d '\r')" || fail "client not installed"
[ -f "$S/linuxarm64/steamclient.so" ] && pass "first start finished (linuxarm64/steamclient.so)" || fail "first start not finished"

echo "--- container prerequisites (Steam Linux Runtime uses bubblewrap + user namespaces)"
info "apparmor_restrict_unprivileged_userns=$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo n/a)"
bwrap --unshare-user --ro-bind / / true 2>/dev/null && pass "/usr/bin/bwrap can create a user namespace" \
  || fail "/usr/bin/bwrap cannot create a user namespace (AppArmor?): $(bwrap --unshare-user --ro-bind / / true 2>&1 | head -1)"

echo "--- Vulkan on the desktop"
vulkaninfo --summary 2>/dev/null | grep -E 'driverName|deviceName' | sed 's/^/info  /'

echo "--- compatibility tools the client has downloaded"
ls -d "$S"/steamapps/common/*/ 2>/dev/null | xargs -rn1 basename | sed 's/^/info  /'

echo "--- Vulkan inside the Steam Linux Runtime container (what Proton games see)"
rt=$(ls -d "$S"/steamapps/common/SteamLinuxRuntime_4*/ 2>/dev/null | head -1)
if [ -n "$rt" ] && [ -x "$rt/run" ]; then
  out=$("$rt/run" -- vulkaninfo --summary 2>&1)
  echo "$out" | grep -E 'driverName|deviceName|apiVersion' | sed 's/^/info  /'
  echo "$out" | grep -q 'driverName *= *turnip' && pass "container uses turnip" || { fail "container does not use turnip"; echo "$out" | tail -15 | sed 's/^/info  /'; }
else
  info "SteamLinuxRuntime 4 not downloaded yet (it comes with the first Proton game)"
fi

echo "--- last client log lines"
tail -n 15 "$HOME/steam-arm64.log" 2>/dev/null | sed 's/^/info  /'
grep -hiE 'vulkan|turnip|llvmpipe|lavapipe' "$S/logs/console-linux.txt" "$S/logs/systeminfo.txt" 2>/dev/null | tail -8 | sed 's/^/info  /'
echo "--- memory"
free -m | sed 's/^/info  /'
echo "=== end"
