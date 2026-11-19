# Architecture

How this homelab is put together: what runs where, how traffic gets in, how
changes get deployed, and which conventions every app follows.

For the bootstrap/install order see [README.md](README.md); for agent-specific
workflow rules see [CLAUDE.md](CLAUDE.md).

---

## 1. The stack, bottom to top

| Layer | What | Notes |
| --- | --- | --- |
| Hardware | Ryzen 7 5800X, 32 GB DDR4-3600, 2×4 TB NVMe, RTX 2080 | single box |
| Hypervisor | Proxmox | VMs for the k8s nodes |
| OS | Talos Linux | immutable, API-driven; no SSH |
| Cluster | Kubernetes — `ctrl-01` (control plane) + `work-01` (worker) | |
| CNI / LB / Gateway | Cilium (kube-proxy replacement, eBPF) | L2 announcements, Gateway API, Maglev LB |
| GitOps | ArgoCD | this repo is the only source of truth |
| Storage | rancher local-path provisioner | `local-path` StorageClass, node-local, `Retain` |
| Databases | CloudNative-PG operator | one PG `Cluster` per app namespace |
| Secrets | Bitnami sealed-secrets | encrypted at rest in git |
| Observability | kube-prometheus-stack + Loki + Alloy | Grafana at `grafana.erikak.no` |

Talos specifics that shape the config:

- Static IPs live in the machine config under `machine.network.interfaces` — the
  boot-time `ip=` kernel parameter does not survive a reboot.
- Talos images come from [factory.talos.dev](https://factory.talos.dev/), with
  schematics defined in `infra/tofu/talos.tf`: the control plane gets
  `qemu-guest-agent`; the worker also gets the NVIDIA open GPU kernel modules
  and container toolkit (the RTX 2080 is passed through to it).
- Machine configs, Talos secrets and the Proxmox VMs are OpenTofu
  (`infra/`); host-level Proxmox setup is in `infra/proxmox-host.md`.
- etcd / kube-scheduler / kube-controller-manager / kube-proxy scraping is
  **disabled** in `applications/monitoring/values.yaml` — Talos does not expose
  them on the standard ports, so scraping them only produces noise.
- Cilium runs with `kubeProxyReplacement: true`, `k8sServiceHost: localhost`,
  `k8sServicePort: 7445` (Talos' KubePrism endpoint) and `cgroup.autoMount:
  false`.

---

## 2. Repository layout

```
homelab/
├── infra/             # below the cluster: OpenTofu (Proxmox VMs, Talos) + host notes
├── setup-homelab/     # platform layer — reconciled by ArgoCD ("platform" ApplicationSet)
│   ├── platform/          #  AppProject + ApplicationSet for the components below
│   ├── sealed-secrets/    #  secret encryption
│   ├── cilium/            #  CNI, L2 announcements, Gateway API, LB IP pool
│   ├── gateway/           #  GatewayClass + Gateway + wildcard cert
│   ├── cert-manager/      #  Let's Encrypt via Cloudflare DNS-01
│   ├── cloudflared/       #  Cloudflare Tunnel (public ingress)
│   ├── playitgg/          #  L4 (TCP/UDP) exposure, paid tier
│   ├── argocd/            #  ArgoCD itself (self-managed after bootstrap)
│   ├── storage/           #  local-path provisioner (own ApplicationSet + AppProject)
│   └── tailscale/         #  Tailscale operator — applied manually, NOT ArgoCD-managed, unused
└── applications/      # workload layer — auto-discovered by ArgoCD
    ├── project.yaml         # AppProject "applications"
    ├── application-set.yaml # git-directory generator over applications/*
    └── <app>/               # one directory == one ArgoCD Application == one namespace
```

Both layers are reconciled continuously, but **platform apps are deliberately
more conservative**: an explicit list instead of a directory scan, `prune:
false`, and no resources-finalizer. Removing a file or deleting an
Application never deletes the CNI, cert-manager or ArgoCD; that cleanup is
manual. Only Cilium and ArgoCD have to be applied by hand on a fresh cluster
(see the rebuild steps in `CLAUDE.md`); ArgoCD then adopts them.

`setup-homelab/tailscale/` is the exception: applied manually, not under
ArgoCD, and currently unused.

---

## 3. GitOps flow

```
 git push  ──►  GitHub (ErikAndreasKlokk/homelab, branch: main)
                     │
                     │  ArgoCD ApplicationSet: git directory generator
                     │  path: applications/*  ·  revision: HEAD
                     ▼
             one Application per subdirectory
                     │
                     │  CMP plugin "kustomize-build-with-helm"
                     │  (kustomize build --enable-helm)
                     ▼
             ServerSideApply into namespace {{path.basename}}
```

`applications/application-set.yaml` templates every `applications/*` directory
into an ArgoCD `Application` whose name, path and destination namespace are all
`path.basename`. **Creating a new app is therefore just: make a directory with a
`kustomization.yaml` and push.** No ArgoCD resource to hand-write.

Sync policy applied to every app:

| Setting | Value | Why |
| --- | --- | --- |
| `automated.selfHeal` | `true` | manual `kubectl edit` gets reverted — intentional |
| `automated.prune` | `true` | deleting a file deletes the resource |
| `CreateNamespace` | `true` | apps don't need pre-created namespaces |
| `ServerSideApply` | `true` | required for large CRDs (Prometheus, CNPG, Gateway API) |
| `SkipDryRunOnMissingResource` | `true` | lets a CRD and a CR of that CRD land in the same sync |

Vanilla ArgoCD cannot inflate Helm charts referenced from a `kustomization.yaml`.
The workaround is the **`kustomize-build-with-helm` config-management plugin**,
defined in `setup-homelab/argocd/values.yaml` as an extra sidecar container on
the repo-server that runs `kustomize build --enable-helm`. Every Application
selects it via `plugin.name`. This is why apps can mix a Helm chart and plain
YAML in one directory.

Storage gets its own parallel ApplicationSet + AppProject
(`setup-homelab/storage/`) pointed at `setup-homelab/storage/*`, so the
local-path provisioner is reconciled like an app without living under
`applications/`.

### Image tagging and the rollout gotcha

Custom images are published to `ghcr.io/erikandreasklokk/*` by each source
repo's CI and tagged **`:main`** (a reused tag, not `:latest`, not a version).
Deployments set `imagePullPolicy: Always`.

The consequence: pushing a new image produces **no manifest diff**, so ArgoCD
sees nothing to sync and the pod is never recreated. A deploy is therefore two
steps:

```bash
# 1. push source → CI builds and pushes ghcr.io/…:main
# 2. force the pull
kubectl rollout restart deployment/<app> -n <namespace>
```

---

## 4. Networking

### Ingress path (HTTP)

```
        internet
           │  DNS: *.erikak.no → Cloudflare
           ▼
   ┌───────────────────┐
   │ Cloudflare edge   │
   └─────────┬─────────┘
             │  Tunnel "talos-tunnel" (outbound-only; no ports forwarded on the router)
             ▼
   ┌───────────────────────────────┐
   │ cloudflared DaemonSet          │  namespace: cloudflared
   └─────────┬─────────────────────┘
             │  https://cilium-gateway-external.gateway.svc.cluster.local:443
             │  originServerName pinned to *.erikak.no / erikak.no
             ▼
   ┌───────────────────────────────┐
   │ Gateway "external"             │  namespace: gateway
   │ gatewayClassName: cilium       │  address 192.168.1.153
   │ listeners: *.erikak.no + erikak.no, HTTPS/443
   │ TLS: secret cert-erikak        │  allowedRoutes.namespaces: All
   └─────────┬─────────────────────┘
             │  HTTPRoute (one per app, in the app's own namespace)
             ▼
        Service → Pod
```

Key points:

- **No router port-forwarding exists.** The only public path is the Cloudflare
  Tunnel, which dials out. Losing `cloudflared` loses public access, not LAN
  access.
- The Gateway is HTTPS-only; there is no `:80` listener and no HTTP→HTTPS
  redirect route.
- `allowedRoutes: from: All` is what lets each app own its `HTTPRoute` in its own
  namespace instead of centralising routing config in `setup-homelab/gateway/`.
- On the LAN, Cilium **L2 announcements** hand `LoadBalancer` services addresses
  from `CiliumLoadBalancerIPPool` `first-pool` = `192.168.1.155–192.168.1.170`.
  The Gateway's `192.168.1.153` is pinned outside that range.

### TLS

cert-manager holds a Cloudflare API token (sealed) and solves **DNS-01** to issue
a single wildcard certificate for `*.erikak.no` + `erikak.no`, stored as secret
`cert-erikak` in the `gateway` namespace. Every hostname reuses it; adding a
subdomain requires no cert work — just an `HTTPRoute`.

### Hostname inventory

| Host | App | Namespace |
| --- | --- | --- |
| `erikak.no`, `www.erikak.no` | portfolio | `portfolio` |
| `argocd.erikak.no` | ArgoCD UI | `argocd` |
| `budgeting.erikak.no` | budgeting | `budgeting` |
| `bolig.erikak.no` | bolig | `bolig` |
| `klokkprojects.erikak.no` | klokkprojects | `klokkprojects` |
| `immich.erikak.no` | Immich | `immich` |
| `n8n.erikak.no` | n8n | `n8n` |
| `grafana.erikak.no` | Grafana | `monitoring` |
| `jellyfin` / `sonarr` / `radarr` / `prowlarr` / `qbittorrent` `.erikak.no` | media stack | `media` |
| `homelab.playit.plus` | Immich (via playit L4 tunnel) | `immich` |

### The three non-HTTP exposure paths

Gateway API only routes HTTP. Three separate mechanisms cover everything else:

1. **PlayitGG (`setup-homelab/playitgg/`)** — layer-4 TCP/UDP port allocation for
   things like Minecraft. The agent runs in-cluster with a sealed token; the
   tunnel itself is created in the playit dashboard and pointed at a
   `ClusterIP:Port` from `kubectl get svc -n <ns> -o wide`.

2. **`playit-operator` (`applications/playit-operator/`)** — a custom Rust
   operator that turns that manual dashboard step into a CRD. A
   `PlayitTunnel` (`ptun`) names a `Service` + port and a protocol
   (`tcp`/`udp`/`both`), the operator calls the playit V1 API and writes the
   assigned public `host:port` back to `.status.address`. It ships alongside a
   self-managed `playit-agent` Deployment: the operator is the control plane
   (creating tunnels), the agent is the data plane (forwarding traffic), and both
   read the same sealed `playit-agent-key`. Because playit is a layer-4 port
   allocator, one `PlayitTunnel` maps one public address to one Service port —
   there is no host-header routing. *Currently deployed with no `PlayitTunnel`
   resources declared in this repo; existing tunnels are still dashboard-managed.*

3. **Tailscale (`setup-homelab/tailscale/`)** — private access with no public
   surface at all. The Tailscale operator provides `ingressClassName: tailscale`
   for exposing a Service only on the tailnet (`https://<name>.<tailnet>.ts.net`);
   nothing uses it at the moment. Note the operator is applied manually and is
   not reconciled by ArgoCD.

There is also a fourth, app-specific wrinkle: **`applications/immich/caddy-tls.yaml`**.
playit's `.playit.plus` HTTPS tunnels forward raw TCP without terminating TLS, so
a small Caddy Deployment terminates it in-cluster, obtains its own Let's Encrypt
cert for `homelab.playit.plus` (validated *through* the tunnel) and reverse
proxies to `immich-server:2283`. Its Service has a **pinned `clusterIP`
(`10.107.133.79`)** so the dashboard-side tunnel config stays valid across
restarts — don't change it casually.

---

## 5. Storage

Everything lands on the rancher **local-path** provisioner:

```yaml
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer   # PV is created where the pod schedules
reclaimPolicy: Retain                     # deleting a PVC does NOT delete the data
```

Implications that show up all over the manifests:

- All volumes are **ReadWriteOnce and node-local**. Any Deployment mounting one
  uses `strategy: type: Recreate` (see `qbittorrent`) — the
  default RollingUpdate would deadlock, with the new pod waiting for a volume the
  old pod still holds.
- There is no replication and no built-in backup. `Retain` is the only safety
  net; it means a deleted PVC leaves an orphaned PV on disk to be cleaned up by
  hand.
- The media PVC requests **4 Ti** — sized against the raw NVMe, not a quota.

## 6. Databases

CloudNative-PG (`applications/cloudnative-pg/`, Helm chart v0.27.0, namespace
`cnpg-system`) is installed once as an operator. Each app that needs Postgres
declares its own `Cluster` in its own namespace — `bolig`, `budgeting`, `immich`,
`n8n` all do. The shape is consistent:

```yaml
kind: Cluster                      # postgresql.cnpg.io/v1
spec:
  instances: 1                     # single node; no HA
  postgresql.parameters.timezone: Europe/Oslo
  managed.roles: [ <app> ]
  bootstrap.initdb:
    database: <app>
    owner: <app>
    secret.name: <app>-postgresql-secret   # sealed
  storage: { size: 5G, storageClass: local-path }
  monitoring.enablePodMonitor: true        # scraped by kube-prometheus-stack
```

Apps connect to the CNPG-generated read-write service, `<app>-postgresql-rw`.
`bolig` overrides `imageName` to a **pgvecto.rs** image (pinned by digest) for
vector support.

Schema migrations run as one-shot Kubernetes `Job`s (`db-init-job.yaml`) using a
separate `…-migrate` image — e.g. `ghcr.io/erikandreasklokk/bolig-migrate:main`,
which runs `drizzle-kit push --force`.

## 7. Secrets

No plaintext `Secret` is ever committed. The flow:

```bash
kubectl create secret generic <name> --from-file=key=file.txt -n <ns> \
  --dry-run=client -o yaml > secret.yaml    # never commit this
kubeseal -f secret.yaml -w mysealedsecret.yaml   # commit this, delete the above
```

`SealedSecret`s are namespace- and name-bound by the controller's private key, so
a sealed secret cannot be moved between namespaces without resealing. This is
also why sealed-secrets is step 1 of the bootstrap.

## 8. Observability

- **`applications/monitoring/`** — kube-prometheus-stack (v65.1.1): Prometheus
  (30 d / 40 GiB retention on a 45 Gi PVC), Grafana, Alertmanager, node-exporter.
  Prometheus scrapes **all** ServiceMonitors/PodMonitors cluster-wide
  (`*SelectorNilUsesHelmValues: false`), which is what makes CNPG's
  `enablePodMonitor` work with no extra wiring. Alerts go to Discord via a config
  supplied entirely from `alertmanager-discord-sealed-secret.yaml`.
- **`applications/loki/`** — Loki (v6.6.2) for logs + Grafana Alloy (v0.9.2) as
  the collector. The Loki datasource is mounted into Grafana as a ConfigMap
  volume rather than via the sidecar, deliberately: the sidecar writes datasource
  files *after* Grafana boots, so Grafana misses them on a cold start.
- Two Talos accommodations worth knowing: Prometheus runs as **root**
  (`runAsNonRoot: false`) because local-path PVCs need it, and the Prometheus
  Operator **admission webhook is disabled** so ArgoCD doesn't churn on the
  injected `caBundle` — the cost is that invalid `PrometheusRule`s fail silently
  instead of being rejected.

---

## 9. Application inventory

| App | What it is | Image | Postgres | Exposure |
| --- | --- | --- | --- | --- |
| `portfolio` | personal site (SvelteKit) | `ghcr.io/…/portfolio:main` | – | `erikak.no` |
| `budgeting` | budgeting app (SvelteKit) | `ghcr.io/…/budgeting:main` + `budgeting-migrate` | yes | `budgeting.erikak.no` |
| `bolig` | Finn.no housing scraper + Discord alerts | `ghcr.io/…/bolig:main` + `bolig-migrate` | yes (pgvecto.rs) | `bolig.erikak.no` |
| `klokkprojects` | Drive Electric docs site | `ghcr.io/…/klokkprojects:main` | – | `klokkprojects.erikak.no` |
| `immich` | self-hosted photos (Helm chart 0.10.3, vendored) | upstream | yes | HTTPRoute + playit/Caddy |
| `n8n` | workflow automation | `n8nio/n8n:latest` | yes | `n8n.erikak.no` |
| `media` | Jellyfin, Sonarr, Radarr, Prowlarr, qBittorrent | linuxserver.io | – | 5 HTTPRoutes |
| `monitoring` | kube-prometheus-stack | upstream | – | `grafana.erikak.no` |
| `loki` | logs (Loki + Alloy) | upstream | – | internal |
| `cloudnative-pg` | Postgres operator | upstream | – | internal |
| `minecraft`, `minecraft-hardcore` | game servers | `ghcr.io/itzg/minecraft-server:java25` | – | playit L4 (TCP 25565) |
| `playit-operator` | custom Rust operator for playit tunnels | `ghcr.io/…/playit-operator:main` | – | – |

Two apps encode enough hard-won detail to call out:

**`media` — qBittorrent behind ProtonVPN.** gluetun runs as a *native sidecar*
(an init container with `restartPolicy: Always`) rather than a plain sidecar
container, because its `startupProbe` must gate qBittorrent: qBittorrent binds
its listening sockets once at startup, so if it wins the race it binds `eth0` and
announces an address gluetun's firewall drops. All containers share the pod's
network namespace, so routing gluetun's tunnel routes qBittorrent — and if gluetun
dies its firewall rules remain in the namespace, which **is** the kill switch and
is intentional. `dnsPolicy: None` + nameserver `127.0.0.1` forces lookups through
gluetun's DoT proxy so tracker queries don't leak to the ISP resolver. Proton's
NAT-PMP lease is 60 s and the forwarded port changes on every reconnect, so
`VPN_PORT_FORWARDING_UP_COMMAND` runs a script that pushes the new port into
qBittorrent's API at runtime; a hardcoded port would never be the forwarded one.
`FIREWALL_INPUT_PORTS: 8080` is required — without it Sonarr/Radarr cannot reach
the WebUI and the liveness probe restarts the container in a loop.

---

## 10. Conventions to follow when adding an app

1. Create `applications/<app>/` with a `kustomization.yaml`. The directory name
   becomes the Application name *and* the namespace.
2. Include `ns.yaml`, plus `deployment.yaml` / `svc.yaml` / `http-route.yaml` for
   a typical web app — or a `helmCharts:` block in `kustomization.yaml` for an
   upstream chart.
3. Custom images: `ghcr.io/erikandreasklokk/<app>:main` with
   `imagePullPolicy: Always`. Remember the rollout-restart step.
4. Need a database? Add a CNPG `Cluster` + sealed credentials + a `db-init-job.yaml`.
5. Any secret gets sealed with `kubeseal` before it goes near git.
6. Pod security: `runAsNonRoot`, drop `ALL` capabilities,
   `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, and
   `readOnlyRootFilesystem` where the workload tolerates it.
7. Mounting an RWO PVC? Set `strategy: type: Recreate`.
8. Push to `main`. ArgoCD picks it up; there is no `kubectl apply` step.

## 11. Sync status

Since ArgoCD 3.6 (2026-11-19), apps with `ServerSideApply=true` diff on the
server side, so the old permanent `OutOfSync` on CNPG `Cluster`s and
`HTTPRoute`s is gone and all apps normally show `Synced`/`Healthy`. Treat
drift as real now.

The one deliberate exception: the cilium chart regenerates `cilium-ca` and
`hubble-server-certs` on every render, so the platform ApplicationSet ignores
their `/data`.

When verifying a deploy, check **per-resource** health of the `Deployment` and any
`Job` (kept in the Application because `controller.resource.health.persist` is on):

```bash
kubectl get application <app> -n argocd -o json \
  | jq -r '.status.resources[] | "\(.kind)/\(.name): \(.status) \(.health.status)"'
```

`Job` differences on `.spec.podReplacementPolicy` and `.status.terminating` are
already globally ignored in `setup-homelab/argocd/values.yaml`.

If the ArgoCD UI misbehaves after initial setup:

```bash
kubectl -n argocd rollout restart statefulset argocd-application-controller
```
