# DroidVM-dev-fork — crosvm + Gunyah + Ubuntu 26.04 guest, GPU-accelerated Steam

> **Previous approach:** a QEMU/Gunyah/Debian 12 implementation was built and documented first. It is preserved on the `archive/qemu-gunyah-debian12` branch (tag `qemu-debian12-final`), in this repo and in `Spectra00/qemu-gunyah-fork`, if we ever need to reference or pull from it. We moved off it because DroidVM's crosvm backend already has working, benchmarked GPU acceleration for this phone; on QEMU that would have had to be rebuilt from scratch.

## 1. Goal

Run Steam games inside a **protected Gunyah VM** on the phone with real GPU acceleration, using DroidVM's existing **crosvm** backend and its 3D stack:

- Guest: **Ubuntu 26.04 (resolute) arm64**
- GPU route: **drm2kgsl native context**. The guest runs real Turnip over `vdrm`/virtio-gpu; on the host, virglrenderer's DRM native context translates the msm protocol to KGSL ioctls on the Adreno 840.
- Steam: Valve's **native ARM64 Linux Steam client** (public beta) plus **Proton 11 ARM64**, which bundles FEX to run x86 Windows games. x86 Linux-native games additionally need a system FEX install.

The guest-side pieces come from DroidVM's own stack, not new code: `Droid-VM/droidvm-guest-additions` (DKMS `gunyah_guest.ko` + patched `virtio-gpu`) and the `mesa-guest` deb (Droid-VM Mesa with Turnip virtio; one package carries the gfxstream, Venus and drm2kgsl ICDs). The design docs and launch references are in `Droid-VM/droidvm-meta-repo` (`deploy/SETUP.md`, `plans/CROSVM_3D_LAUNCH_REFERENCE.md`, `plans/ACCEPTANCE_REPORT_R5_20260817.md`, `plans/NATIVE_CONTEXT_PLAN.md`).

## 2. Hardware and host

| Item | Value |
|---|---|
| Phone | OnePlus 15 (model PLK110), Snapdragon 8 Elite Gen 5, Adreno 840 |
| Root | bootloader unlocked, KernelSU-Next + ReZygisk; Termux (F-Droid) with `su` |
| Hypervisor | Qualcomm Gunyah via `/dev/gunyah`; protected VMs only (unprotected `VM_INIT` is refused by this RM) |
| Host kernel modules (shipped in the APK under `usr/lib/modules/<kmi>/`, loaded by the app) | `gunyah-host-share`, `gh-unmovable`, `udmabuf`, `nproc-guard` (+ `gunyah-kvcalloc` on 6.1 KMIs) |
| KernelSU module | `gh-hugepage-reserve`. It must be a build from 2026-08-08 or later: older builds caused `Bad page state` and kernel panics on VM teardown in DroidVM's testing. |

## 3. Reference result to reproduce (DroidVM acceptance run R5, 2026-08-17, device "8e5 PLK110")

| Route | vkmark | Minecraft fps |
|---|---|---|
| drm2kgsl (target) | Turnip A840 **949** | **63–75** |
| Venus | 73 (capped by a 60 Hz panel) | 58–60 |
| gfxstream | 8866 | 7–12 (render-thread RT starvation) |

Conditions: guest 3584 MiB, 4 vCPU pinned to host CPUs 2–5, GPU worker cpuset 7, SCHED_FIFO 97, 1400×1050 @120, dpi 160, Native display + GPU-blit (Turnip), dynamic memory sharing on, hugepages on, VNC off, mTHP chunked; base image `ubuntu-2026-kde.qcow2` (Ubuntu resolute cloud arm64 + KDE); `droidvm-guest-additions` r31, `mesa-guest-drm2kgsl` r227687; APK "final9".

**Caveat:** the report says many of the fixes behind that run (crosvm power-key IRQ type, display flip release, qcow2 zero clusters, zink renderpass deadlock) were **uncommitted** at the time. Phase 0 has to establish which of them are in a build we can actually install (see 4.1).

## 4. Phase 0 — bring-up of the proven stack (no Steam yet)

Done when the ladder in 4.7 passes on this phone with drm2kgsl. The runnable steps (inventory, host prep, image + cloud-init seed, VM settings, guest provisioning, checks) are in **`phase0/README.md`**.

### 4.1 Establish exactly which build to run
- This fork's `master` currently equals upstream `Droid-VM/DroidVM` `master` (`5c89691`, published as dev build `0.0.6.r240.5c89691`), plus this README. `CrosvmBackendInstance` already emits the drm2kgsl/Venus/gfxstream arguments (`--pre-alloc drm-host-mb=…,gpu-guest-mb=…`, `context-types=drm`, `udmabuf=true`).
- The crosvm, virglrenderer, gfxstream and Turnip binaries come from the `app/src/main/assets/prebuilts` submodule (`Droid-VM/DroidVM-Prebuilts` @ `c4998e1`). Verify on the phone, from the installed app:
  - `crosvm run --help` lists `--pre-alloc` and `--hypervisor gunyah`;
  - `strings usr/lib/libvirglrenderer.so | grep -i kgsl` is non-empty (drm2kgsl backend present);
  - `libvulkan_freedreno.so` (host Turnip) and `libgfxstream_backend.so` are present.
- If the published prebuilts lack drm2kgsl or the R5 fixes, find the newest upstream build that has them (DroidVM dev releases, `wip/3d-accel` branches) before building anything ourselves.

**Off-device result (2026-10-03).** I extracted `prebuilt-arm64-v8a.tar.xz` from `DroidVM-Prebuilts` @ `c4998e1` (committed 2026-09-12):
- crosvm (sha256 `cd3693ba…a7b`) has `--pre-alloc`, `drm-host-mb`, `gpu-guest-mb`, `Drm2KgslPool`, `GpuPool`, `udmabuf`, `gunyah-pvm`, `transport-cap`, `--prepare-lend-mthp-mode`, `--protected-vm-without-firmware` and `--swiotlb`.
- `libvirglrenderer.so` (sha256 `40b5edaa…633d`) has the KGSL backend (`/dev/kgsl-3d0`, `CROSVM_DRM2KGSL_*`) and the guest-alloc protocol (`MSM_BO_GUEST_ALLOC`, requiring `udmabuf=true` plus a guest pool), plus Venus.
- The host Turnip is Mesa 26.3.0-devel. drm2kgsl doesn't use it; only gfxstream and Venus do.
- It also ships DroidVM's own guest kernel (Linux 6.18.16, 4K pages) and `edk2-gunyah.fd`.
- These files are byte-identical in size to what the phone had installed on 2026-09-30, so the phone most likely already has them; `phase0/host/00-inventory.sh` confirms by hash.
- Not verifiable from strings: whether this crosvm carries the R5-era crosvm fixes (power-key IRQ edge type, display flip release, qcow2 zero clusters) and the virtio-snd `ACCESS_PLATFORM`/chmap fixes. Phase 0's on-device checks cover them (the power button, display reconnect, `/proc/asound/cards`).

Guest side, pinned to the published `droidvm` release line:
- `droidvm-guest-additions` tag **`v0.1.0`** (= branch `droidvm`, 2026-08-30, guest-alloc pool and host-pool probing). `wip/3d-accel` diverges from it with a 7.1-kernel compile fix; use that only if the guest kernel is 7.1+.
- `mesa-guest_26.3.0-devel+droidvm.r227672.gcecc0e96_arm64.deb` (ferls2077/mesa-cross release `droidvm`, Droid-VM/mesa `droidvm` @ `cecc0e9`, which includes the `0x44050a00` Adreno 840 virtio IDs). It is slightly older than R5's `r227687`.
- Ubuntu 26.04 `resolute-server-cloudimg-arm64.img` (2026-09-27) ships kernel `7.0.0-34-generic`, inside the guest additions' `^7\.` build range.

### 4.2 Host preparation (from DroidVM's launch reference)
- The app daemon loads the kernel modules. After a phone reboot, confirm `gunyah-host-share`, `gh-unmovable` and `udmabuf` are loaded before a manual launch.
- `echo 4096 > /sys/module/udmabuf/parameters/size_limit_mb`, otherwise blob imports stall at 64 MB.
- `ulimit -l unlimited` for crosvm (it refuses to SHARE a pool it cannot mlock).
- `--swiotlb` is required: without it `VM_START` fails with `No such device (os error 19)`. `--prepare-lend-mthp-mode chunked` is also needed: without it the host reclaims guest pages and you get random SIGBUS.
- **Never `kill -9` crosvm:** it leaks RM memparcels until the phone reboots. Stop the guest with `systemctl poweroff`, or use `kill -TERM`. Run only one crosvm at a time (two fight over the pool and get `ENOMEM`).

### 4.3 Guest image
- Ubuntu 26.04 resolute **cloud arm64** image (DroidVM used `ubuntu-resolute-cloud-arm64-<date>.qcow2`). Ubuntu's 7.0 generic kernel has `CONFIG_DMA_RESTRICTED_POOL`, which protected-VM virtio needs.
- Boot via **UEFI** (EDK2 → the guest's own GRUB → `/boot`), which is the app's production path, so `update-initramfs` inside the guest is enough after module changes. The DroidVM drm2kgsl launcher uses `--protected-vm-without-firmware` with EDK2 as the payload (`--protected-vm` goes through pvmfw, which this RM's low-memory donation breaks).
- Give the image credentials before first boot (a cloud-init NoCloud seed, or a rescue boot), and plan disk space: the image must hold Steam and games.

### 4.4 VM configuration in the app (crosvm backend)
- Backend crosvm, hypervisor Gunyah, protected mode as the app defaults it for Gunyah (protected without firmware), UEFI on.
- Memory: 4096 MiB to start (R5 used 3584 MiB). Guest RAM comes from the gh_hugepage_reserve pool, about 5.4 GB on this 12 GB phone (model CPH2749), which is the ceiling for Steam; add zram inside the guest. 4 vCPUs, pinned as in section 3.
- Graphics: virtio-gpu screen on; renderer **virglrenderer**, mode **Native** (= drm2kgsl), provider Turnip; guest pool (`gpu-guest-mb`) on with udmabuf; display exporter Native.
- Network: the app's bridge/tap. Audio: virtio-snd. DroidVM fixed the protected-VM `ACCESS_PLATFORM` and chmap bugs in crosvm (`048f7374e`); check that the installed crosvm has them.

### 4.5 Guest provisioning
1. `curl -L https://raw.githubusercontent.com/Droid-VM/droidvm-guest-additions/wip/3d-accel/install.sh | sudo bash`. This installs the DKMS package for 7.x kernels and refreshes the initramfs; `virtio_gpu` must then load from `updates/dkms`.
2. Install one `mesa-guest` deb (prefix `/usr/local`). Either build it with `Droid-VM/droidvm-meta-repo` `8_build_guest_mesa.sh` / `ferls2077/mesa-cross` (targets Ubuntu 26.04), or use a published release. Guest Mesa and the host decoder must come from matching versions.
3. `/etc/environment`: `VK_DRIVER_FILES=/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json`, plus `MESA_LOADER_DRIVER_OVERRIDE=zink` for GL on Vulkan. Restart the display manager.

### 4.6 Things to check right after provisioning
- guest `dmesg`: `has_create_guest_handle=1`, the drm_buddy pool line, no `command 0x203` errors;
- host log: no `host access to lent memory region` (if present, the guest kernel lacks the restricted pool or a device does not negotiate `ACCESS_PLATFORM`);
- `cat /proc/asound/cards` shows the VirtIO SoundCard, and `speaker-test` is audible.

### 4.7 Acceptance ladder
VNC/native display shows the desktop → `vulkaninfo` reports `driverName = turnip` with an Adreno 840 device via virtio → `vkcube` → `vkmark` (in a real desktop session) → optionally Minecraft, compared against section 3.

### 4.8 App-side items carried over from the archive (evaluate, don't assume)
- The `nativeForkExec` CLOEXEC fix (`archive/qemu-gunyah-debian12`, `eb65e52`): **not ported.** `master` still has the original child path, and crosvm is launched through the same `NativeProcess`. But the original "crash" evidence turned out to be libsigchain logging the launcher's own deliberate signal reset (the archived QEMU handoff, section 20). The real failures on that path were QEMU option-parsing errors, and DroidVM's R5 run launched crosvm on this phone with this exact code. Revisit only if a crosvm launch dies before `execve`.
- The pinned debug key makes CI builds update in place, but it must never reach `master`: `dev-release.yml` publishes from `master`, and `release.yml` publishes on any tag push. Keep it off branches that publish.

## 5. Phase 1 — Steam (after Phase 0 passes)
- Requirements: 4 KiB pages (Ubuntu arm64 generic uses 4 KiB), a working Vulkan driver (drm2kgsl Turnip), unprivileged user namespaces for the Steam Linux Runtime container, and enough guest RAM and disk.
- Install Valve's ARM64 Linux Steam client (beta), then enable Proton 11 ARM64 for Windows titles. Install FEX (with its x86 rootfs) for x86 Linux-native titles. Fallback: Canonical's `steam` snap (x86 Steam under FEX), which targets Ubuntu.
- First targets: a light native ARM64 or Proton title, then something DXVK-heavy.

## 6. Known limits from DroidVM's own testing
- Guest vblank is tied to the phone panel's real refresh rate: at 60 Hz it caps Venus/drm2kgsl throughput, and ColorOS often picks 60 Hz.
- After leaving and returning to the display, the picture can take 10–60 s to come back.
- An unprovisioned image (no guest additions/Mesa) shows a black or frozen screen on the 3D routes. SSH in and provision.
- drm2kgsl `vkmark` on A840 (949) is far below A830 (8625); Minecraft is still 63–75 fps. Expect to investigate if Steam titles underperform.
- No zram/swap in the guest by default; memory pressure stalls the desktop.
