terraform {
  required_version = ">= 1.10"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.123"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
  }

  # State and plans hold the Talos cluster CA keys and the Proxmox token, so
  # they are always encrypted. Losing the passphrase means re-importing
  # everything; keep it in the password manager.
  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.state_passphrase
    }
    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }
    state {
      method   = method.aes_gcm.main
      enforced = true
    }
    plan {
      method   = method.aes_gcm.main
      enforced = true
    }
  }
}

# Endpoint and token come from PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN
# (see README). The SSH block is only used for the few operations the API
# cannot do, such as uploading files.
provider "proxmox" {
  ssh {
    agent       = false
    username    = "root"
    private_key = file(pathexpand(var.proxmox_ssh_key))
  }
}
