# Talos cluster: secrets, machine configs, and the installer images.
#
# The secrets were imported from the original `talosctl gen config` output, so
# this manages the existing cluster rather than a new one.

locals {
  cluster_endpoint = "https://${var.network.controlplane_ip}:6443"

  nodes = {
    controlplane = {
      hostname = "controlplane"
      ip       = var.network.controlplane_ip
      type     = "controlplane"
    }
    worker = {
      hostname = "worker"
      ip       = var.network.worker_ip
      type     = "worker"
    }
  }
}

# Imported from the original secrets. Do NOT add arguments here (not even
# talos_version): any change makes the provider regenerate every cluster CA,
# which would lock all nodes out of the cluster.
resource "talos_machine_secrets" "this" {
  lifecycle {
    prevent_destroy = true
    ignore_changes  = all
  }
}

# --- Installer images ------------------------------------------------------

resource "talos_image_factory_schematic" "base" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = ["siderolabs/qemu-guest-agent"]
      }
    }
  })
}

# Worker has the RTX 2080 passed through (proxmox.tf). NVIDIA's open kernel
# modules support Turing; keep the toolkit on the same driver branch.
resource "talos_image_factory_schematic" "worker_gpu" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent",
          "siderolabs/nvidia-open-gpu-kernel-modules-production",
          "siderolabs/nvidia-container-toolkit-production",
        ]
      }
    }
  })
}

locals {
  schematic_ids = {
    controlplane = talos_image_factory_schematic.base.id
    worker       = talos_image_factory_schematic.worker_gpu.id
  }

  # Per-node extras on top of the common patch.
  node_patches = {
    controlplane = []
    worker = [
      yamlencode({
        machine = {
          kernel = {
            modules = [
              { name = "nvidia" },
              { name = "nvidia_uvm" },
              { name = "nvidia_drm" },
              { name = "nvidia_modeset" },
            ]
          }
          sysctls = {
            "net.core.bpf_jit_harden" = "1"
          }
          # What the nvidia-device-plugin DaemonSet selects on (no NFD here).
          nodeLabels = {
            "nvidia.com/gpu.present" = "true"
          }
        }
      })
    ]
  }
}

# --- Machine configs -------------------------------------------------------

data "talos_machine_configuration" "this" {
  for_each = local.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.type
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_config_contract
  kubernetes_version = var.kubernetes_version
  docs               = false
  examples           = false

  config_patches = concat([
    yamlencode({
      machine = {
        network = {
          hostname = each.value.hostname
          interfaces = [{
            interface = "ens18"
            dhcp      = false
            addresses = ["${each.value.ip}/${var.network.prefix}"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = var.network.gateway
            }]
          }]
        }
        install = {
          disk  = "/dev/sda"
          image = "factory.talos.dev/installer/${local.schematic_ids[each.key]}:${var.talos_version}"
          wipe  = false
        }
      }
    })
  ], local.node_patches[each.key])
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [var.network.controlplane_ip]
  nodes                = [for n in local.nodes : n.ip]
}

resource "talos_machine_configuration_apply" "this" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = var.network.controlplane_ip

  # A change that needs a reboot gets staged for the next one instead of
  # rebooting the node mid-apply.
  apply_mode = "staged_if_needing_reboot"
}

# Imported: the cluster was bootstrapped long before tofu.
resource "talos_machine_bootstrap" "this" {
  node                 = var.network.controlplane_ip
  endpoint             = var.network.controlplane_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  lifecycle {
    prevent_destroy = true
  }
}
