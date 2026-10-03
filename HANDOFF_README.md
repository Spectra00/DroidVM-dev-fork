# DroidVM-dev-fork — QEMU backend + Gunyah + Debian 12 guest (final state, archived)

> **Status: archived 2026-10-03.** This fork's first effort used DroidVM's **QEMU** backend (with the patched QEMU from `Spectra00/qemu-gunyah-fork`) to run a protected Debian 12 guest on a OnePlus 15 (Snapdragon 8 Elite Gen 5 / Adreno 840). It reached a booted, networked XFCE desktop. The project then moved to DroidVM's **crosvm** backend + an Ubuntu 26.04 guest, which already has working, benchmarked GPU acceleration on this phone. This file is the app-side record of the QEMU effort, frozen on the `archive/qemu-gunyah-debian12` branch / `qemu-debian12-final` tag.
>
> The full technical story (QEMU fixes, SIGBUS root cause, guest kernels, desktop setup, open issues) is in `Spectra00/qemu-gunyah-fork` → `HANDOFF_README.md` on its `archive/qemu-gunyah-debian12` branch. This file covers only what changed in the app.

## App-side fixes (all verified on the phone unless noted)

| Branch | Commits | What it fixes | CI run |
|---|---|---|---|
| `fix/native-fork-exec-cloexec` | `9817aa3`, `eb65e52`, `6596b50` | `NativeProcess.nativeForkExec` (`app/src/main/cpp/unixhelper/native_process.c`) crashed the forked child before `execve`: it `close()`d every inherited fd of the ART process while the old signal handlers were still installed. Now inherited fds are marked `CLOEXEC` with `close_range` (fcntl fallback), signal handlers and mask are reset right after the `dup2`s, and every step writes a breadcrumb to stderr and to `/data/data/cn.classfun.droidvm/run/forkexec-trace.log`. | 36947212545, 36951214333 |
| `ci/pin-debug-keystore` (also inside the next row) | `a68b0e5` / `65ca981` | Pins the debug signing key in the repo so CI builds from any branch update in place (`pm install -r`) instead of forcing an uninstall that wipes VM configs. **Security:** the key is public, so it must not be merged into a branch that produces a published release (the upstream `dev` release workflow builds debug-signed APKs from `master`). | 36949062701 |
| `fix/qemu-drive-explicit-format` | `43924e9`, `62ba3a3`, `3e231d9` | Every `-drive` now gets an explicit `format=`. QEMU's probing silently treated qcow2 as raw, because the QEMU fork had no qcow2 driver. `3e231d9` makes the CI APK artifact a single installable `app-debug.apk` (it used to download as the exploded APK contents). | 36979987834, 36982034500 |
| `feat/retry-gunyah-vm-start-enodev` | `b219be5`, `a4e38ee`, `410050d` | The launcher half of the QEMU fork's exit-status-83 mitigation: when `GH_VM_START` is rejected with `ENODEV`, relaunch after a bounded backoff, with a fresh retry budget per user-initiated start. Also ignores a duplicate start of the same VM within 1 s. **Never installed together with the rows above.** | — |
| `fix/duplicate-vm-start` | `593bfbf` | The duplicate-start guard alone, on `master`. | — |
| `diag/native-fork-breadcrumbs` | — | Diagnostic-only variant of the fork/exec breadcrumbs. | — |

The archive branch merges `fix/qemu-drive-explicit-format` (which already contains the cloexec, keystore and breadcrumb work) and `feat/retry-gunyah-vm-start-enodev` on top of `master`, so the tag holds the complete app-side state in one tree. `master` itself was not changed.

## Last installed build

`fix/qemu-drive-explicit-format` @ `3e231d9`, `app-debug.apk` sha256 `363d82a8ca5a632a85cb73a802d0fb6afbee0bdb4331ab6c132b0a0bc7617f6a`. It was installed with `cp` to `/data/local/tmp`, then `pm install -r` (system_server cannot read `/sdcard`). The APK unpacks its own bundled `qemu-system-aarch64` on install, so the patched QEMU from the QEMU fork had to be copied back into `/data/data/cn.classfun.droidvm/usr/bin/` after every reinstall.

VM settings, guest kernel, disks and the full device list are in the QEMU fork's handoff (section 29).

## Observations about the app (not fixed)

- QEMU backend (`QemuBackendInstance.buildGpuCommand`): VirGL emits `virtio-gpu-gl-pci` and GfxStream emits `virtio-gpu-rutabaga-pci`, both with `-display egl-headless` and `blob=on`. The QEMU fork supports none of these, so only the 2D renderer works on QEMU. All real GPU acceleration (gfxstream, Venus, drm2kgsl, the guest-alloc pool, udmabuf) is implemented only in `CrosvmBackendInstance`.
- The console tabs show only `[droidvm] VM exited (code -1)` for a VM that dies before its UART connects. The real record is `/data/data/cn.classfun.droidvm/cache/daemon.log` and `cache/console_<uuid>_{stderr,stdio,uart}.log`.
- Exit code `-7` in `daemon.log` means the process was killed by signal 7 (`-WTERMSIG`).
- The display pane has a dimming overlay until the tool panel is opened (app UI).
