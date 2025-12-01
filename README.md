# homelab
My proxmox kubernetes homelab running on:

- 32gb 3600MHz DDR4 ram
- 2x4Tb NVMe SSD
- 8 core ryzen 7 5800x
- Nvidia Geforce RTX 2080

Read how i got here at [my blog.](https://www.erikak.no/blog)

## install order

- [setup-homelab/sealed-secrets](/setup-homelab/sealed-secrets)
- [setup-homelab/cilium](/setup-homelab/cilium)
- [setup-homelab/cert-manager](/setup-homelab/cert-manager)
- [setup-homelab/gateway](/setup-homelab/gateway)
- [setup-homelab/cloudflared](/setup-homelab/cloudflared)
- [setup-homelab/argocd](/setup-homelab/argocd)
- [setup-homelab/playitgg](/setup-homelab/playitgg)

## nice commands to remember for myself

```bash
kubectl create secret generic name \
  --from-file=key=file.txt \
  -n namespace \
  --dry-run=client -o yaml > secret.yaml
```

```bash
kubeseal -f secret.yaml -w mysealedsecret.yaml
```