# The two Talos VMs. Adopted from the hand-built originals with `tofu import`,
# so these blocks describe what already exists; change them deliberately.
#
# reboot_after_update = false: a change that needs the VM offline fails the
# apply instead of silently rebooting a node (and with one worker, every app).

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

  memory {
    dedicated = 26624
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
