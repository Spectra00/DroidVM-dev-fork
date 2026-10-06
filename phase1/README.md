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

## E. Result: Ori and the Blind Forest (2026-10-06)

The first Proton ARM64 title, played on the phone. Steam was started over SSH (`steam-ssh`). After launch, the Steam web helpers were paused and paged out (`webhelper-pageout`). Measured over SSH with `free -m` and `vmstat 2 10` while the game was running:

| | First run | VM memory raised | **+ web helpers paged out** |
|---|---|---|---|
| guest RAM (`free` total) | 3540 MB | 3892 MB | 3892 MB |
| `available` | 688 MB | 799 MB | **1078 MB** |
| `free` | 133 MB | 99 MB | **385 MB** |
| swap (zram) used | 1511 MB | 1099 MB | 1505 MB (paused helpers parked there) |
| `si` while playing (KB/s) | 0–666, most samples non-zero | 0 (one sample of 2) | **0 (one sample of 18)** |
| `so` | 0 | 0 | 0 |
| CPU `us`+`sy` / `st` | ~36 % / 7–10 % | ~37 % / 7–10 % | ~38 % / 8–10 % |

Memory is no longer the limit. Swap-in during play went to about zero, and about 1 GB stays available. What was left was host CPU contention: `st` (steal) stayed at 8–10 %, with the audio still choppy at times. Fixed below (*Audio*).

Process memory (RSS) during play: `ori.exe` 904 MB; the 8 paused `steamwebhelper` went from 1066 MB to 676 MB RSS, 156 MB PSS.

### What was set up for that run
VM (DroidVM editor):
- VM memory raised from 4096 MB. It must stay within the hugepage pool: `pool_want=2768` × 2 MB = 5536 MB, which covers RAM plus the 1024 MB guest-alloc prealloc.
- Sound: Buffer **High quality (12 buffers)**, underrun **WSOLA**.

Steam launch options for the game:
```
PROTON_LOG=1 PULSE_LATENCY_MSEC=60 DXVK_FRAME_RATE=60 %command%
```
Drop `PROTON_LOG=1` once nothing needs debugging.

Guest:
- PipeWire: `pw-metadata -n settings 0 clock.force-quantum 1024` (until reboot).
- zram swap the size of RAM (already in Phase 0).
- `systemctl --user set-property plasma-plasmashell.service MemoryHigh=220M`: caps the desktop shell; its excess goes to zram instead of RAM.
- Discover notifier and `kaccess` autostarts hidden; screen auto-lock off (`kscreenlockerrc` `Autolock=false`, `LockOnResume=false`).
- Konsole and System Monitor closed while playing; monitoring over SSH instead.

### Audio: choppy playback fixed (2026-10-06)
Checked on the host, nothing was pinned: the 4 vCPU threads, the GPU worker (`kgsl-sync`) and crosvm's sound process (`/proc/self/exe device snd`, re-executed under the app uid) could all run on any of cores 0–7, at normal priority.

What fixed it, one change at a time:
1. **vCPU Affinity** on (VM editor → CPU): vCPU 0–3 → host cores 2, 3, 4, 5, one core each. **GPU Worker Cpuset** on, core 7. Steal dropped from 8–10 % to 4–8 % (one spike of 16). Audio still choppy.
2. Sound process pinned to the cores left free (0–1) with `taskset`, and its main thread set to `SCHED_FIFO` 10 with `chrt`. Audio still choppy.
3. **PipeWire quantum back at 1024.** `pw-metadata ... clock.force-quantum` resets on every guest reboot and was back at 0, so the guest was running PipeWire's small default buffer. Made permanent with `~/.config/pipewire/pipewire.conf.d/10-quantum.conf` (`default.clock.quantum` and `default.clock.min-quantum` = 1024). **Audio clean.**

`pw-top` during play afterwards: output node QUANT 1024, ERR 5→7 then flat; the game's stream (quantum 720) ERR 10→12 then flat.

The guest buffer was most likely the main fix. The pinning stays because it costs nothing and keeps the sound path off the vCPU cores. DroidVM now does step 2 itself at every VM start, so no command is needed for it (`SoundHostPlacement`; see `CrosvmBackendInstance.placeSoundDevice`):
- The sound process goes on the host cores no vCPU and no GPU worker cpuset use, little cores only when any are free; here that is 0–1.
- Its main thread gets `SCHED_FIFO` 10. When no vCPU is pinned, only the priority is set.
- The result is logged as `sound device placed: pid … cpus=…`.
- **Confirmed on the phone (2026-10-06):** after an app update and a VM restart, with no manual commands, the sound process showed `Cpus_allowed_list: 0-1` and `SCHED_FIFO` priority 10 (build from `test/snd-pinning-signed`, same code).

A rare, brief graphical stutter remains. It most likely comes from DXVK compiling shaders, or FEX translating code, on first sight of a new area (shader pre-caching is off: `-noshaders`). It's not from the pinning. To test that, give every vCPU `2-5` instead of one core each.

### Tools
- `guest/steam-ssh`: starts Steam on the desktop from an SSH login. A plain `steam-arm64 &` over SSH fails with `Unable to open X11 display` and dies with the SSH session. Alternative: `systemd-run --user --collect --unit=steam-arm64 ~/.local/bin/steam-arm64 -cef-disable-gpu`, stopped with `systemctl --user stop steam-arm64`.
- `guest/webhelper-pageout`: `sudo webhelper-pageout` after the game has started pauses every `steamwebhelper` (SIGSTOP) and pages their memory out to zram with `process_madvise(MADV_PAGEOUT)`. Killing them instead makes Steam respawn them or restart. Run `webhelper-pageout --resume` before opening Steam's window or overlay again. Paste multi-line files over SSH: pasting into the native display interleaves lines.

Install both:
```sh
for f in steam-ssh webhelper-pageout; do curl -fsSL -o ~/.local/bin/$f https://raw.githubusercontent.com/Spectra00/DroidVM-dev-fork/master/phase1/guest/$f; chmod +x ~/.local/bin/$f; done
```

## If something fails
- **Steam window never appears:** paste the last 40 lines of `~/steam-arm64.log` and `~/.local/share/Steam/logs/bootstrap_log.txt`.
- **Game window black or it exits at once:** paste the `PROTON_LOG=1` log and `40-steam-check.sh` output.
- **Guest freezes or the OOM killer fires:** watch `free -m`. The client's web UI is heavy for 3.5 GB; close other apps, and page the web helpers out (section E). Don't `kill -9` crosvm; shut down from inside the guest.
- **x86 Linux games** (no Windows build): not covered yet; they need Valve's FEX tool, which is a later step.
