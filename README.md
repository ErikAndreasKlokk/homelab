# homelab
My proxmox kubernetes homelab running on:

- 32gb ddr4 ram
- 8 core ryzen 7 5800x
- 1.5 Tb ssd
- Nvidia Geforce RTX 2080

Read how i got here at [my blog.](https://erikak.no/blog)

## install order

- [setup-homelab/sealed-secrets](/setup-homelab/sealed-secrets)
- [setup-homelab/cilium](/setup-homelab/cilium)
- [setup-homelab/cert-manager](/setup-homelab/cert-manager)
- [setup-homelab/gateway](/setup-homelab/gateway)
- [setup-homelab/cloudflared](/setup-homelab/cloudflared)
- [setup-homelab/argocd](/setup-homelab/argocd)

## nice commands to remember for myself

```bash
kubeseal -f secret.yaml -w mysealedsecret.yaml
```