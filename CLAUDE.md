# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Cluster access — ALWAYS use the `new-homelab-project` skill

For **any** operation against the live homelab cluster — checking deployment /
rollout status, viewing pod logs, triggering a rollout, sealing secrets, or
running `kubectl` / `kubeseal` / `gh` — invoke the **`new-homelab-project`**
skill. It provides the kubeconfig/credentials and the exact workflow.

Do **not** conclude "I have no cluster access" or hand the commands back to the
user: the default `kubectl` context on this machine points at a dead Docker
Desktop cluster and `gh` is unauthenticated, but the skill gives you everything
you need. This has come up before — use the skill instead of giving up.

Note on rollouts: custom images use the reused `:main` tag, so ArgoCD sees no
manifest diff and will **not** auto-restart the pod after a new image is pushed.
After CI builds the image, trigger `kubectl rollout restart deployment/<app> -n
<ns>` (via the skill) to pull the new image.

## What This Is

A GitOps homelab running on Proxmox + Talos Linux with ArgoCD for continuous deployment. All resources are declared in YAML and automatically synced by ArgoCD — there is no manual `kubectl apply` workflow for day-to-day changes.

**Hardware**: Ryzen 7 5800X, 32GB DDR4, 2×4TB NVMe, RTX 2080.

**Read [ARCHITECTURE.md](ARCHITECTURE.md) before making non-trivial changes.** It documents the full traffic path (Cloudflare Tunnel → Cilium Gateway → HTTPRoute), the three non-HTTP exposure mechanisms (playitgg, playit-operator, Tailscale), the local-path storage constraints, the CNPG database pattern, the per-app inventory, and the conventions for adding a new app. This file covers workflow rules; that one covers how the system is built.

## Architecture

```
homelab/
├── setup-homelab/    # Platform/infrastructure layer (install once, in order)
└── applications/     # User-facing apps (discovered by ArgoCD ApplicationSet)
```

**Platform layer** (`setup-homelab/`) is reconciled by ArgoCD too: the
`platform` ApplicationSet (`setup-homelab/platform/`) covers `sealed-secrets`,
`cilium`, `gateway`, `cert-manager`, `cloudflared`, `playitgg` and `argocd`
itself, and the `storage` ApplicationSet covers local-path. Platform apps have
**prune off and no resources-finalizer**: removing a file or an Application
never deletes the CNI/ArgoCD/cert-manager; clean up by hand. Only
`setup-homelab/tailscale/` is still applied by hand (and nothing uses it).

The layer below (Proxmox VMs, Talos) is OpenTofu in `infra/` — see
`infra/README.md`.

**Rebuilding from scratch** (ArgoCD ≥ 3.3 CRDs are too big for client-side
apply, so everything is `--server-side`):

1. Nodes: `infra/tofu` → `tofu apply`, then `talosctl kubeconfig`.
2. Gateway API CRDs:
   `kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml`
3. Cilium (nothing schedules without a CNI):
   `kubectl kustomize --enable-helm setup-homelab/cilium | kubectl apply --server-side -f -`
4. Restore the sealed-secrets keys **before** the controller starts, or every
   SealedSecret in git is undecryptable:
   `kubectl apply -f ~/backups/sealed-secrets-keys-<date>.yaml`
5. ArgoCD:
   `kubectl kustomize --enable-helm setup-homelab/argocd | kubectl apply --server-side -f -`
6. Hand the rest to ArgoCD:
   `for k in setup-homelab/platform setup-homelab/storage applications; do kubectl apply --server-side -k $k; done`

ArgoCD then adopts cilium/argocd and installs everything else; platform apps
retry until their CRDs exist.

**Applications layer** (`applications/`) is auto-discovered by ArgoCD's `application-set.yaml`. Each app subdirectory is its own ArgoCD Application. Apps include: budgeting (custom image from ghcr.io), n8n, Immich, CloudNative-PG, Minecraft, portfolio.

## Key Conventions

**Kustomize + Helm**: ArgoCD uses a custom plugin (`kustomize-build-with-helm`) that runs `kustomize build` with Helm chart support. The typical app layout is:
```
applications/<app>/
├── kustomization.yaml   # references helm chart and patches
├── Chart.yaml           # helm dependency
├── values.yaml          # helm values
└── *-sealedsecret.yaml  # encrypted secrets (never plain secrets)
```

**Sealed Secrets**: All sensitive values must be sealed before committing. The workflow:
```bash
# Create a plain secret (dry-run only — never commit this)
kubectl create secret generic <name> \
  --from-file=key=file.txt \
  -n <namespace> \
  --dry-run=client -o yaml > secret.yaml

# Seal it (commit the output, discard secret.yaml)
kubeseal -f secret.yaml -w mysealedsecret.yaml
```

**ArgoCD sync settings**: Apps use `selfHeal: true`, `prune: true`, `CreateNamespace=true`, and `ServerSideApply=true`. The `ignoreDifferences` blocks on `Job` resources are common to avoid ArgoCD re-applying one-shot jobs.

**Image pull policy**: Custom images use `imagePullPolicy: Always` with the `main` tag (not `latest`) so rollouts pick up new pushes without version bumps.

**Security contexts**: Containers run non-root, drop `ALL` capabilities, and use read-only root filesystems where feasible.

**Database**: CloudNative-PG operator manages PostgreSQL clusters. Apps connect via the CNPG-generated service and credentials (sealed). Initialization jobs run as one-shot Kubernetes Jobs.

## Networking

- External access: Cloudflare Tunnel (`cloudflared`) terminates outside; it proxies to the internal Cilium gateway service at `https://cilium-gateway-external.gateway.svc.cluster.local:443`.
- Internal LB: Cilium L2 announcements hand out IPs from a pool to `LoadBalancer` services.
- TLS: cert-manager issues wildcard cert for `*.erikak.no` stored in secret `cert-erikak` in the `gateway` namespace.
- All HTTP routes are HTTPS-only via the Gateway.
- TCP/UDP services (e.g. Minecraft) are exposed via PlayItGG. After sealing the agent token and applying the component, create a tunnel in the PlayItGG dashboard and point it at the `ClusterIP:Port` from `kubectl get svc -n <namespace> -o wide`.

## Troubleshooting

If the ArgoCD UI throws errors after initial setup, restart the application controller:
```bash
kubectl -n argocd rollout restart statefulset argocd-application-controller
```

**ArgoCD is v3.6** (since 2026-11-19). Apps use `ServerSideApply=true`, which
in 3.6 also means server-side diff, so the old permanent `OutOfSync` on CNPG
`Cluster`s and `HTTPRoute`s is gone, and the `media` app (gluetun native sidecar)
syncs again. If an app does show unexpected drift, look at it; it's no longer
"known noise".

When verifying a deploy, check the **per-resource** health of `Deployment` and any `Job`
(per-resource health is kept in the Application via `controller.resource.health.persist`):
```bash
kubectl get application <app> -n argocd -o json | jq -r '.status.resources[] | "\(.kind)/\(.name): \(.status) \(.health.status)"'
```
Don't try to "fix" the CNPG/HTTPRoute/SealedSecret drift unless that's the actual task.

## Talos Cluster Setup (reference)

VMs, Talos machine configs/secrets and installer images (factory.talos.dev schematics) are managed by OpenTofu in `infra/tofu` — read `infra/README.md` before changing them, and always `talosctl apply-config --dry-run` a rendered config first. Control plane `ctrl-01`: 4 CPU / 4 GB / 200 GB; worker `work-01`: 12 CPU / 24 GB / 3.5 TB + the RTX 2080 (PCI passthrough).

Static IPs are set in the machine config (not via DHCP) under `machine.network.interfaces`, generated from `var.network` in `infra/tofu/variables.tf` — the boot-time `ip=` kernel parameter is lost on reboot. The original `talosctl gen config` output (`~/_out` in WSL) has been imported into tofu state; keep it only as an encrypted backup.
