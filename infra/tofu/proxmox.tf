# The two Talos VMs. Adopted from the hand-built originals with `tofu import`,
# so these blocks describe what already exists; change them deliberately.
#
# reboot_after_update = false: a change that needs the VM offline fails the
# apply instead of silently rebooting a node (and with one worker, every app).

# GPU passthrough. The host must already bind the card to vfio-pci
# (infra/proxmox-host.md); a mapping lets the API token attach it, since raw
# PCI ids require root@pam.
resource "proxmox_hardware_mapping_pci" "gpu" {
  name    = "rtx2080"
  comment = "RTX 2080 for the Talos worker (Jellyfin NVENC, Immich ML)"
  map = [{
    node         = var.proxmox_node
    path         = "0000:08:00.0"
    id           = "10de:1e87"
    subsystem_id = "1462:3726"
    iommu_group  = 16
    comment      = "TU104 [GeForce RTX 2080 Rev. A] (MSI)"
  }]
}

resource "proxmox_virtual_environment_vm" "controlplane" {
  node_name = var.proxmox_node
  vm_id     = 100
  name      = "ctrl-01"

  machine       = "q35"
  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0", "ide2", "net0"]
  on_boot       = true

  reboot_after_update = false

  agent {
    enabled = true
  }

  cpu {
    cores   = 4
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "local"
    interface    = "scsi0"
    file_format  = "qcow2"
    size         = 200
    iothread     = true
  }

  cdrom {
    interface = "ide2"
    file_id   = "local:iso/metal-amd64.iso"
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "BC:24:11:95:E0:9E"
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  node_name = var.proxmox_node
  vm_id     = 101
  name      = "work-01"

  machine       = "q35"
  bios          = "seabios"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0", "ide2", "net0"]
  on_boot       = true

  reboot_after_update = false

  agent {
    enabled = true
  }

  cpu {
    cores   = 12
    sockets = 1
    type    = "x86-64-v2-AES"
  }

  # 24 GB, not 26: with a PCI device attached, Proxmox pins all guest RAM up
  # front, and 26 + 4 GB of VMs left the 32 GB host about 700 MB.
  memory {
    dedicated = 24576
  }

  # RTX 2080 (see proxmox_hardware_mapping_pci.gpu). Only the VGA function is
  # passed; the card's audio/USB functions stay bound to vfio-pci on the host.
  hostpci {
    device  = "hostpci0"
    mapping = proxmox_hardware_mapping_pci.gpu.name
    pcie    = true
    rombar  = true
  }

  disk {
    datastore_id = "local"
    interface    = "scsi0"
    file_format  = "qcow2"
    size         = 3500
    iothread     = true
  }

  cdrom {
    interface = "ide2"
    file_id   = "local:iso/metal-amd64.iso"
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "BC:24:11:59:3C:90"
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    prevent_destroy = true
  }
}
