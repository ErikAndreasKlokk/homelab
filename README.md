# homelab

My proxmox kubernetes homelab running on:

- 32gb 3600MHz DDR4 ram
- 2x4Tb NVMe SSD
- 8 core ryzen 7 5800x
- Nvidia Geforce RTX 2080

Talos Linux on Proxmox, Cilium for networking, ArgoCD for GitOps. Everything in
`applications/` is deployed automatically from this repo — no `kubectl apply`.

Read how i got here at [my blog.](https://www.erikak.no/blog)

**[ARCHITECTURE.md](ARCHITECTURE.md)** — how it all fits together: traffic flow,
GitOps setup, storage, secrets, conventions for adding an app.

## install order

The VMs and Talos come from OpenTofu ([infra/](infra/README.md)). On the
cluster, only Cilium and ArgoCD are applied by hand; ArgoCD then adopts them
and installs the rest of `setup-homelab/` (the `platform` ApplicationSet),
storage and `applications/`:

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
kubectl kustomize --enable-helm setup-homelab/cilium | kubectl apply --server-side -f -
kubectl apply -f ~/backups/sealed-secrets-keys-<date>.yaml   # restore keys before the controller starts
kubectl kustomize --enable-helm setup-homelab/argocd | kubectl apply --server-side -f -
for k in setup-homelab/platform setup-homelab/storage applications; do kubectl apply --server-side -k $k; done
```

Set your own LAN range in `setup-homelab/cilium/ip-pool.yaml` first.

[setup-homelab/tailscale](setup-homelab/tailscale) is optional and applied
manually — it is not managed by ArgoCD.

## what's running

`applications/` — portfolio, budgeting, bolig, klokkprojects, immich, n8n, the
media stack (jellyfin/sonarr/radarr/prowlarr/qbittorrent), monitoring
(prometheus/grafana/alertmanager), loki, cloudnative-pg, minecraft,
playit-operator.

Adding one is just a new directory under `applications/` with a
`kustomization.yaml` — ArgoCD's ApplicationSet discovers it on push. See
[ARCHITECTURE.md](ARCHITECTURE.md#10-conventions-to-follow-when-adding-an-app).

## nice commands to remember for myself

Seal a secret (never commit the plain one):

```bash
kubectl create secret generic name \
  --from-file=key=file.txt \
  -n namespace \
  --dry-run=client -o yaml > secret.yaml
```

```bash
kubeseal -f secret.yaml -w mysealedsecret.yaml
```

Custom images use a reused `:main` tag, so ArgoCD sees no diff after a new push —
restart the deployment to pull it:

```bash
kubectl rollout restart deployment/<app> -n <namespace>
```

Check per-resource health (the rolled-up app status lies, see
[ARCHITECTURE.md](ARCHITECTURE.md#11-known-noisy-signals-not-bugs)):

```bash
kubectl get application <app> -n argocd -o json \
  | jq -r '.status.resources[] | "\(.kind)/\(.name): \(.status) \(.health.status)"'
```
