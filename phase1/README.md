# Phase 1 kit — Steam (native ARM64) on the drm2kgsl guest

Prerequisite: Phase 0 done (`../phase0/`). Every `20-check.sh` line PASS, Vulkan is Turnip on Adreno 840, and vkmark runs. The VM uses 4096 MB plus zram swap (`zram-tools`, zstd, 100 %).

Steam here is **Valve's native linuxarm64 client**. It is not the Ubuntu `steam` package, which is x86 and wants i386 multiarch, and it is not the snap, which brings its own Mesa and would bypass Turnip. Windows games run through **Proton ARM64**: Wine ARM64EC, with FEX for the x86 code inside, and DXVK/VKD3D on the system Vulkan driver. The client downloads it. Background: `../HANDOFF_README.md`, section 5.

## A. Install (over SSH or in Konsole, inside the guest, as your user)
```sh
curl -fsSLO https://raw.githubusercontent.com/Spectra00/DroidVM-dev-fork/master/phase1/guest/30-steam-install.sh
bash 30-steam-install.sh
```
It must end with `== done`.

## B. First start (in the Plasma session)
Menu → Games → **Steam (ARM64)**, or in Konsole: `~/.local/bin/steam-arm64 &`, then `tail -f ~/steam-arm64.log`.

The first start downloads the rest of the client and exits on its own; the launcher then starts it again. Expect one or two self-update restarts. Sign in.

## C. Check
```sh
curl -fsSLO https://raw.githubusercontent.com/Spectra00/DroidVM-dev-fork/master/phase1/guest/40-steam-check.sh
bash 40-steam-check.sh | tee ~/phase1-check.txt
```
Paste it back. Run it again after the first game launch: the line that matters is `container uses turnip`, which means Proton games see the drm2kgsl driver and not llvmpipe.

## D. First games
1. Steam → Settings → Compatibility → **Enable Steam Play for all other titles**. Pick the ARM64 Proton the list offers (`proton-stable-arm64` / "Proton … (ARM64)"). Restart Steam when asked.
2. Start with something light, for example a 2D or DX9/DX11 indie title. Install it, launch it, then run `40-steam-check.sh` again and note the fps.
3. Only after that, try one DXVK-heavy title.

Per-game launch options worth knowing (Properties → Launch options):
- `PROTON_LOG=1 %command%` writes `~/steam-<appid>.log`; paste it when a game fails.
- `PROTON_USE_WINED3D=1 %command%` runs the game on OpenGL (zink) instead of DXVK, for comparison.

## If something fails
- **Steam window never appears:** paste the last 40 lines of `~/steam-arm64.log` and `~/.local/share/Steam/logs/bootstrap_log.txt`.
- **Game window black or it exits at once:** paste the `PROTON_LOG=1` log and `40-steam-check.sh` output.
- **Guest freezes or the OOM killer fires:** watch `free -m`. The client's web UI is heavy for 3.5 GB; close other apps. Don't `kill -9` crosvm; shut down from inside the guest.
- **x86 Linux games** (no Windows build): not covered yet; they need Valve's FEX tool, which is a later step.
