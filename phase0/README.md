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
| udmabuf (guest-alloc) | not shown for Native Context: the app always passes `udmabuf=true` on this route (the switch appears only for GfxStream) |
| VRAM size (MB) | 1024 (default) |
| Dynamic vram | either way. With Guest preallocation = VRAM size (1024) and allocation step 0 the whole pool is set aside at boot and never grows, which is the same as off |
| SimpleFB screen | off |
| Network | add one adapter (without it crosvm gets no `--net` and the guest has no NIC). Turn **SNAT** on and add the port forward `tcp 2222:22`. The guest sits on DroidVM's own NAT network (192.168.188.0/24), which Android doesn't route to, so SSH goes through the forward: `ssh -p 2222 <username>@127.0.0.1` |
| Audio | virtio-snd on |

Start it. First boot takes a few minutes: cloud-init creates the user, installs the SSH key and grows the disk. Expect a black or frozen screen until step E. That's expected on the 3D routes before the guest additions and Mesa are installed. Log in on the serial console, or SSH in from Termux through the port forward: `ssh -p 2222 <username>@127.0.0.1`. If the network adapter was added after the first boot, cloud-init wrote no netplan; create one matching `en*` with DHCP (see "If something fails").

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

## E½. Make the guest network static (do this once, over SSH)
The DHCP lease from DroidVM's NAT network was lost when systemd-networkd restarted during boot. Pin the address the port forward points at, and keep cloud-init from rewriting it (replace the MAC with yours from `ip -br link`):
```
echo 'network: {version: 2, ethernets: {enp0s8: {match: {macaddress: "02:80:7a:bf:43:2f"}, set-name: enp0s8, dhcp4: false, addresses: [192.168.188.64/24], routes: [{to: default, via: 192.168.188.1}], nameservers: {addresses: [1.1.1.1, 8.8.8.8]}}}}' | sudo tee /etc/netplan/50-cloud-init.yaml
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
sudo netplan apply
```

## If something fails
- **Can't log in (password rejected):** stop the VM, then run `bash ~/phase0/host/03-make-seed.sh <username> <newpassword>` and start the VM again. The new seed has a new instance-id, so cloud-init re-applies the user, password and SSH key. Use letters and digits only; symbols can get lost through the native display's keyboard mapping.
- **No network (`ip -br link` shows only `lo`):** the VM has no network adapter; add one (step D). If the NIC exists but has no address: `sudo tee /etc/netplan/60-dvm.yaml` with `network: {version: 2, ethernets: {wired: {match: {name: "en*"}, dhcp4: true}}}`, then `sudo chmod 600` it and `sudo netplan apply`.
- **Black screen after step E + reboot:** check `20-check.sh` over SSH. The usual causes are the in-tree `virtio_gpu` still loading (run `update-initramfs -u` and reboot) or Mesa not installed.
- **`VM_START` / `No such device (os error 19)`:** retry once after 10 s (a known transient Resource Manager race). If it persists, paste the app's crosvm log.
- **`host access to lent memory region`** in the host log: either the guest kernel lacks the restricted pool or a device does not negotiate `ACCESS_PLATFORM`. Paste the line; the device name is in it.
- **DKMS build fails:** check `uname -r`. For 7.1+ kernels re-run step E with `GA_REF=wip/3d-accel`.
