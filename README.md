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

Bootstrap the platform layer by hand, in this order:

- [setup-homelab/sealed-secrets](setup-homelab/sealed-secrets)
- [setup-homelab/cilium](setup-homelab/cilium) — install the Gateway API CRDs first, and set your own LAN range in `ip-pool.yaml`
- [setup-homelab/gateway](setup-homelab/gateway)
- [setup-homelab/cert-manager](setup-homelab/cert-manager)
- [setup-homelab/cloudflared](setup-homelab/cloudflared)
- [setup-homelab/playitgg](setup-homelab/playitgg)
- [setup-homelab/argocd](setup-homelab/argocd)

Each one is applied with:

```bash
kubectl kustomize --enable-helm setup-homelab/<component>/ | kubectl apply -f -
```

Gateway API CRDs, before cilium:

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
```

Then storage and the apps — after this ArgoCD takes over and git drives everything:

```bash
kubectl kustomize --enable-helm setup-homelab/storage/ | kubectl apply -f -
kubectl kustomize --enable-helm applications/ | kubectl apply -f -
```

[setup-homelab/tailscale](setup-homelab/tailscale) is optional and applied
manually — it is not managed by ArgoCD.

## what's running

`applications/` — portfolio, budgeting, bolig, klokkprojects, immich, n8n, the
media stack (jellyfin/sonarr/radarr/prowlarr/qbittorrent), monitoring
(prometheus/grafana/alertmanager), loki, cloudnative-pg, minecraft,
claude-code, playit-operator.

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
