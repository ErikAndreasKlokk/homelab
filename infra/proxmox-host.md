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

## GPU passthrough (RTX 2080 → worker VM)

See the next section once done.
