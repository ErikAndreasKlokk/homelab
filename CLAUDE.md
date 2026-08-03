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

**Platform layer** (`setup-homelab/`) must be bootstrapped manually in this order. Each component is applied with:
```bash
kubectl kustomize --enable-helm setup-homelab/<component>/ | kubectl apply -f -
```

1. `sealed-secrets` — encrypts secrets stored in git
2. `cilium` — CNI, load balancing (L2 announcements), Gateway API. **Before applying**, install the Gateway API CRDs first:
   ```bash
   kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
   ```
   Also update `cilium/ip-pool.yaml` with your own LAN IP range.
3. `gateway` — Kubernetes Gateway API config (wildcard `*.erikak.no`, IP `192.168.1.153`)
4. `cert-manager` — TLS via Let's Encrypt + Cloudflare DNS validation
5. `cloudflared` — Cloudflare Tunnel for external access
6. `playitgg` — additional port forwarding for TCP/UDP services (paid tier)
7. `argocd` — GitOps controller; after this, the repo drives everything

Then apply storage and the applications layer:
```bash
kubectl kustomize --enable-helm setup-homelab/storage/ | kubectl apply -f -
kubectl kustomize --enable-helm applications/ | kubectl apply -f -
```

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

**Expected ArgoCD drift (not a real problem):** Several resource kinds report `OutOfSync` / `Degraded` permanently because their controllers mutate the live object or have no ArgoCD health check — this rolls up to a misleading app-level `OutOfSync`/`Degraded`. Known cases:
- `Cluster` (CloudNative-PG) and `HTTPRoute` (Gateway API) — perpetually `OutOfSync` (controller adds status/default fields; no `ignoreDifferences` configured).
- `SealedSecret` — shows `Degraded` health (known ArgoCD health-check quirk for the CRD).

When verifying a deploy, check the **per-resource** health of `Deployment` and any `Job` — not the rolled-up app status:
```bash
kubectl get application <app> -n argocd -o json | jq -r '.status.resources[] | "\(.kind)/\(.name): \(.status) \(.health.status)"'
```
Don't try to "fix" the CNPG/HTTPRoute/SealedSecret drift unless that's the actual task.

## Talos Cluster Setup (reference)

Talos image is built at [factory.talos.dev](https://factory.talos.dev/) — the current image includes the `cloudflared` and `qemu-guest-agent` extensions. VM sizing used: 4 CPU / 4GB RAM / 100GB disk for the controlplane node (`ctrl-01`); worker node (`work-01`) sized as desired.

Static IPs are set in the machine config (not via DHCP) under `machine.network.interfaces`. After generating configs with `talosctl gen config`, edit `_out/controlplane.yaml` and `_out/worker.yaml` to add static network config before applying — the boot-time `ip=` kernel parameter is lost on reboot.
