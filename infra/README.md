# infra — the layer below ArgoCD

ArgoCD owns everything inside the cluster (`applications/`). This directory owns
what the cluster runs *on*:

| Path | What | Tool |
| --- | --- | --- |
| `tofu/` | Proxmox VMs, Talos machine configs/secrets/installer images | OpenTofu |
| `proxmox-host.md` | One-time host setup (disk mirror, GPU passthrough) | by hand, documented |

## Secrets live outside this (public) repo

Everything sensitive sits in WSL under `~/.config/homelab/` (mode 600) and must
also be in the password manager:

| File | What |
| --- | --- |
| `proxmox.env` | `PROXMOX_VE_ENDPOINT` + API token for `tofu@pve` (role `OpenTofu`) |
| `tofu.env` | `TF_VAR_state_passphrase`: state/plan encryption passphrase |
| `talos-secrets.yaml` | Talos cluster secrets bundle (was imported into state) |
| `~/backups/sealed-secrets-keys-*.yaml` | sealed-secrets controller keys; without them every SealedSecret in git is undecryptable after a rebuild |

The Proxmox SSH fallback uses `~/.ssh/proxmox_claude` (root@proxmox).

State is local (`infra/tofu/terraform.tfstate`, gitignored) and always
encrypted. Back it up together with the passphrase, or move it to a remote
backend (e.g. Cloudflare R2) with `tofu init -migrate-state`.

## Usage

```bash
. ~/.config/homelab/proxmox.env; . ~/.config/homelab/tofu.env
cd infra/tofu
tofu plan
tofu apply
tofu output -raw talosconfig > ~/.talos/config
```

### Changing a node's Talos config safely

Render first and let Talos show the diff before applying:

```bash
tofu apply -refresh-only
tofu output -json machine_configs | jq -r .worker > /tmp/worker.yaml
talosctl -n 192.168.1.152 apply-config --dry-run -f /tmp/worker.yaml
```

`talos_machine_configuration_apply` uses `staged_if_needing_reboot`, so a change
that needs a reboot is staged for the next reboot instead of rebooting the node.
From Talos 1.14 that mode always resolves to `auto`; switch to `staged` then.

The dry-run diff prints a few lines of context, which can include
`cluster.id`/`cluster.secret`. Don't paste it anywhere public.

### Upgrading Talos / changing extensions

Tofu updates the *installer image* in the machine config, but it does not run
upgrades. After changing `talos_version` or a schematic and applying:

```bash
talosctl -n <ip> upgrade --image "$(tofu output -json installer_images | jq -r .<node>)"
```

One minor version at a time, control plane first. The worker is the only
worker, so its upgrade means a few minutes of downtime for every app.

## Guard rails

- `talos_machine_secrets` was imported and has `ignore_changes = all`. Never
  add arguments to it: any change regenerates every cluster CA.
- VMs, secrets and bootstrap have `prevent_destroy`.
- VMs have `reboot_after_update = false`: a change that needs the VM offline
  fails the apply instead of rebooting a node.
- `talos_config_contract` stays at the version the cluster was created with;
  bump `talos_version` for upgrades instead.

## Changing networks (moving)

Keep the new router on `192.168.1.0/24` (gateway `192.168.1.2` today) and nothing
changes. Otherwise: edit `var.network` in `tofu/variables.tf`, and change the
Proxmox host's own IP by hand (`/etc/network/interfaces`, `/etc/hosts`). If the
host is unreachable after a move, connect a laptop directly with a cable, give
it a `192.168.1.x/24` address and SSH to `192.168.1.150`.
