# Phase 0 kit — crosvm + Ubuntu 26.04 + drm2kgsl bring-up

Run these steps in order on the phone. Each step produces output to paste back. Background and the reasoning behind each choice are in `../HANDOFF_README.md` (section 4).

**Copy the kit to Termux first** (Termux, normal user):
```sh
pkg install -y git
git clone --depth 1 https://github.com/Spectra00/DroidVM-dev-fork ~/dvm && cp -r ~/dvm/phase0 ~/phase0
```

## A. Inventory (read-only)
```sh
su -c 'sh /data/data/com.termux/files/home/phase0/host/00-inventory.sh'
```
This writes `/sdcard/Download/phase0-inventory.txt`; paste it back. What it settles:
- whether the installed app's crosvm, virglrenderer and Turnip match the published prebuilts (`Droid-VM/DroidVM-Prebuilts` @ `c4998e1`); those were checked off-device to contain the drm2kgsl backend with guest allocation;
- which host modules are loaded, the KernelSU `gh-hugepage-reserve` build, the udmabuf limit, free RAM and storage, and the panel refresh rate.

## B. Host preparation (after every phone reboot)
Open the DroidVM app once (its daemon loads the kernel modules), then:
```sh
su -c 'sh /data/data/com.termux/files/home/phase0/host/01-host-prep.sh'
```
It must end with `host ready`.

## C. Guest disk + cloud-init seed (Termux, normal user)
```sh
pkg install -y curl qemu-utils dosfstools mtools openssh
bash ~/phase0/host/02-make-image.sh <username> <password> 64G
```
This downloads Ubuntu 26.04 `resolute-server-cloudimg-arm64.img` (kernel 7.0.0-34), checks it against Ubuntu's SHA256SUMS, grows it to 64 GB, and writes a `CIDATA` seed disk. Both land in `/storage/emulated/0/DroidVM/Ubuntu-26.04/`. Pick the disk size with Steam in mind; it can be grown later.

## D. Create the VM in DroidVM
New VM with these settings (labels as shown in the app):

| Section | Setting |
|---|---|
| Backend | **CrosVM** (hypervisor Gunyah) |
| Protected VM | the app's default for Gunyah (protected **without firmware**) |
| Boot | **UEFI on** (EDK2 → Ubuntu's own GRUB). No kernel or initrd paths |
| Disks | 1: `resolute-server-cloudimg-arm64.qcow2` (virtio, boot). 2: `seed-cidata.img` (virtio) |
| CPU / memory | 4 vCPUs, **4096 MB**. Guest RAM is served from `gh_hugepage_reserve`'s pool, which on this 12 GB phone is capped near `RAM − min(RAM/2, 6144 MB)` ≈ 5.4 GB, so more than about 5 GB won't fit. DroidVM's own test used 3584 MB. The VRAM size below is part of guest RAM. |
| Graphics → virtio-gpu screen | on, 1408×1050 (a width that's a multiple of 16 keeps the GPU blit path), exporter **Native** |
| Renderer | **VirGL** (virglrenderer) |
| Graphics API | **Native Context** (this is drm2kgsl) |
| udmabuf (guest-alloc) | **on** |
| VRAM size (MB) | 1024 (default) |
| SimpleFB screen | off |
| Network | default (bridge/tap) |
| Audio | virtio-snd on |

Start it. First boot takes a few minutes: cloud-init creates the user, installs the SSH key and grows the disk. Expect a black or frozen screen until step E. That's expected on the 3D routes before the guest additions and Mesa are installed. Log in on the serial console, or find the guest IP with `ip -4 a` and SSH in from Termux (`ssh <username>@<ip>`).

## E. Provision the guest
Inside the guest:
```sh
curl -fsSLO https://raw.githubusercontent.com/Spectra00/DroidVM-dev-fork/master/phase0/guest/10-provision.sh
sudo bash 10-provision.sh kde
sudo systemctl reboot
```
This installs `droidvm-guest-additions` **v0.1.0** (DKMS) and `mesa-guest 26.3.0-devel+droidvm.r227672` (includes the Adreno 840 virtio IDs), points Vulkan at Turnip and GL at zink, and installs KDE Plasma + SDDM.

Don't `kill -9` crosvm and don't force-stop the app while the VM runs. Shut down from inside the guest (`sudo systemctl poweroff`) or with the app's power button.

## F. Checks
In a terminal inside the Plasma session:
```sh
curl -fsSLO https://raw.githubusercontent.com/Spectra00/DroidVM-dev-fork/master/phase0/guest/20-check.sh
bash 20-check.sh | tee ~/phase0-check.txt
```
Paste the output back. Phase 0's target is every line `PASS`, in particular `driverName = turnip` on `Adreno (TM) 840`, `has_create_guest_handle=1`, the guest-alloc pool line, and a sound card.

## G. Acceptance ladder
In the Plasma session: `vkcube`, then `sudo apt install -y vkmark && vkmark`. Compare against DroidVM's reference on this phone: drm2kgsl vkmark **949**, Minecraft 63–75 fps. Note the panel refresh rate while testing; at 60 Hz it caps the result.

## If something fails
- **Black screen after step E + reboot:** check `20-check.sh` over SSH. The usual causes are the in-tree `virtio_gpu` still loading (run `update-initramfs -u` and reboot) or Mesa not installed.
- **`VM_START` / `No such device (os error 19)`:** retry once after 10 s (a known transient Resource Manager race). If it persists, paste the app's crosvm log.
- **`host access to lent memory region`** in the host log: either the guest kernel lacks the restricted pool or a device does not negotiate `ACCESS_PLATFORM`. Paste the line; the device name is in it.
- **DKMS build fails:** check `uname -r`. For 7.1+ kernels re-run step E with `GA_REF=wip/3d-accel`.
