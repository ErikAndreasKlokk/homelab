variable "state_passphrase" {
  description = "Passphrase for OpenTofu state/plan encryption (TF_VAR_state_passphrase)."
  type        = string
  sensitive   = true
}

variable "proxmox_ssh_key" {
  description = "Private key for root@proxmox, used by the provider's SSH fallback."
  type        = string
  default     = "~/.ssh/proxmox_claude"
}

variable "proxmox_node" {
  description = "Proxmox node name."
  type        = string
  default     = "proxmox"
}

# Everything that changes when the LAN changes lives here. Keep the new
# router on 192.168.1.0/24 and none of it has to change.
variable "network" {
  description = "LAN addressing for the cluster nodes."
  type = object({
    prefix          = number
    gateway         = string
    controlplane_ip = string
    worker_ip       = string
  })
  default = {
    prefix          = 24
    gateway         = "192.168.1.2"
    controlplane_ip = "192.168.1.151"
    worker_ip       = "192.168.1.152"
  }
}

variable "cluster_name" {
  type    = string
  default = "talos-proxmox-cluster"
}

variable "talos_version" {
  description = "Talos version installed on the nodes (used for the installer image)."
  type        = string
  default     = "v1.10.6"
}

variable "talos_config_contract" {
  description = "Talos version the machine configs are generated for. Pin to the version the cluster was created with; do not bump on upgrades."
  type        = string
  default     = "v1.10.6"
}

variable "kubernetes_version" {
  type    = string
  default = "1.33.1"
}
