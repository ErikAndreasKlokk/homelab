# Proxmox host setup (by hand)

Host: `proxmox`, 192.168.1.150, PVE 9.1, Ryzen 7 5800X (no iGPU), 32 GB,
2× Samsung 990 EVO Plus 4 TB (`nvme0n1`, `nvme1n1`), RTX 2080.

These are one-time changes to the host OS. They are written down here so a
reinstall can repeat them; tofu does not manage the host itself.

## Disk mirror (done 2026-11-19)

Both NVMe disks have the same layout: `p1` BIOS boot, `p2` 1 GB ESP, `p3` LVM PV.
VG `pve` spans both, and `root` + `swap` are LVM `raid1` (one leg per disk).
Both ESPs are managed by `proxmox-boot-tool`, and the UEFI boot order lists
`proxmox` (disk 1) and `proxmox (disk 2)`.

What was done, starting from a stock install on `nvme1n1` with an empty
`nvme0n1`:

```bash
sgdisk -R /dev/nvme0n1 /dev/nvme1n1 && sgdisk -G /dev/nvme0n1   # copy partition table
partx -u /dev/nvme0n1
pvcreate /dev/nvme0n1p3 && vgextend pve /dev/nvme0n1p3

# The stock VG has 0 free extents and raid1 needs a 4 MiB metadata LV per leg,
# so swap was shrunk by 64M first (via a temporary swap LV on nvme0, so that
# swapoff couldn't starve the host of RAM).
lvreduce --fs ignore -L -64M pve/swap && mkswap /dev/pve/swap

printf 'dm-raid\nraid1\n' >> /etc/initramfs-tools/modules
lvconvert --type raid1 -m 1 pve/swap /dev/nvme0n1p3
lvconvert --type raid1 -m 1 pve/root /dev/nvme0n1p3
update-initramfs -u -k all

umount /boot/efi        # and comment out its /etc/fstab line
proxmox-boot-tool format /dev/nvme0n1p2
proxmox-boot-tool init /dev/nvme0n1p2 grub
proxmox-boot-tool init /dev/nvme1n1p2 grub
efibootmgr -c -d /dev/nvme0n1 -p 2 -L "proxmox (disk 2)" -l '\EFI\proxmox\shimx64.efi'
```

Check health: `lvs -a -o name,sync_percent,devices pve`, `proxmox-boot-tool status`.

Replacing a dead disk: partition the new disk with `sgdisk -R`, `pvcreate`,
`vgextend pve`, `lvconvert --repair pve/root` (and `pve/swap`), then
`proxmox-boot-tool format` + `init` its ESP.

## GPU passthrough (RTX 2080 → worker VM) (done 2026-11-19)

The card is IOMMU group 16 on its own: `08:00.0` VGA `10de:1e87`, `.1` audio
`10de:10f8`, `.2` USB `10de:1ad8`, `.3` USB-C UCSI `10de:1ad9`. The host binds
all four to `vfio-pci` at boot. **The 5800X has no iGPU, so the host has no
screen after boot;** use SSH or the web UI (and the cable trick in
`README.md` if the network is wrong).

```bash
cat > /etc/modprobe.d/vfio.conf <<'CONF'
options vfio-pci ids=10de:1e87,10de:10f8,10de:1ad8,10de:1ad9 disable_vga=1
softdep nouveau pre: vfio-pci
softdep nvidiafb pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
softdep xhci_pci pre: vfio-pci
softdep i2c_nvidia_gpu pre: vfio-pci
CONF
printf 'blacklist nouveau\nblacklist nvidiafb\nblacklist i2c_nvidia_gpu\n' > /etc/modprobe.d/blacklist-nvidia-host.conf
printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' | tee -a /etc/initramfs-tools/modules > /etc/modules-load.d/vfio.conf
# IOMMU is on by default on AMD; amd_iommu=on is not a valid value
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt"/' /etc/default/grub
update-initramfs -u -k all && proxmox-boot-tool refresh && reboot
```

Check: `lspci -nnk -s 08:00` shows `vfio-pci` for all four functions.

Everything after that is in tofu: the `rtx2080` PCI mapping, `hostpci0` on the
worker VM (memory cut to 24 GB, since passthrough pins all guest RAM), and the
worker's Talos image with `nvidia-open-gpu-kernel-modules-production` +
`nvidia-container-toolkit-production` plus the NVIDIA kernel modules. Check on
the node: `talosctl -n 192.168.1.152 read /proc/driver/nvidia/version`.

## Host access for automation

- `tofu@pve` with role `OpenTofu` on `/`, API token `tofu@pve!homelab`
  (privilege separation off).
- root SSH key `claude-homelab-admin` in `/root/.ssh/authorized_keys` (remove
  that line to revoke).
