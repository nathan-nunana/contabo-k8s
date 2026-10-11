# Design: single-node k3s on a Contabo VPS

## Goal

Turn an existing Contabo VPS (Ubuntu 24.04) into a hardened,
production-ready single-node Kubernetes cluster with ingress, TLS, persistent
storage, monitoring, alerting and backups, from one command, repeatably.

## Decisions

| Area        | Choice                                   | Why |
|-------------|------------------------------------------|-----|
| Provisioning| None, the VPS already exists             | Contabo VPSes are bought monthly; nothing to create |
| Config tool | Ansible                                  | Idempotent host configuration over SSH |
| Kubernetes  | k3s, pinned version, embedded etcd       | Small footprint; etcd gives scheduled snapshots |
| Ingress     | Traefik bundled with k3s, HTTP → HTTPS   | Already installed; ingress-nginx is retired (March 2026) |
| TLS         | cert-manager + Let's Encrypt HTTP-01     | Staging and prod ClusterIssuers |
| Storage     | k3s local-path + `local-path-retain` SC  | Longhorn cannot replicate on one node |
| Monitoring  | kube-prometheus-stack                    | Prometheus, Grafana, Alertmanager in one chart |
| Alerting    | Email via SMTP                           | Works with any mail provider |
| Heartbeat   | Watchdog alert → healthchecks.io         | A dead server can't alert about itself |
| Backups     | etcd snapshots every 6h, 7 days, local   | Undo mistakes; off-server copies are a later step |
| Hardening   | sudo user, key-only SSH, UFW, fail2ban, unattended-upgrades | Baseline for a public VPS |
| Platform    | Shared CloudNativePG Postgres and MinIO, Redis per tenant | One server per service for every app; isolation per tenant (see platform.md) |

## Flow

1. `make bootstrap` connects as root, creates the admin user, proves that user
   can SSH in and sudo, and only then disables root and password login.
2. `make deploy` connects as the admin user and runs hardening, k3s and add-ons.
   Helm runs on the VPS against the local kubeconfig, so the only tools needed
   on the workstation are Ansible and its collections.
3. `make verify` checks the node, pods, scrape targets, the Grafana certificate,
   HTTPS and the HTTP redirect.

## Firewall

- Public: 22 (rate limited), 80, 443
- 6443 (Kubernetes API): admin CIDRs only
- 10.42.0.0/16 and 10.43.0.0/16 (pod and service CIDRs): allowed, otherwise UFW
  drops in-cluster traffic

k3s's iptables rules sit ahead of UFW, so NodePort and hostPort services bypass
the firewall. Restricting NodePorts with kube-proxy's `nodeport-addresses` was
considered and rejected: it risks breaking how ServiceLB forwards 80/443 to
Traefik, and that can't be confirmed without a live cluster. The README tells
users to expose apps only through Ingress.

## Monitoring

k3s runs the controller manager, scheduler and kube-proxy inside one process,
so kube-prometheus-stack's separate scrape jobs for them are disabled; they
would only fire false TargetDown alerts.

Extra scrape targets: Traefik (PodMonitor on port `metrics`) and cert-manager
(ServiceMonitor on `http-metrics`). They are applied after kube-prometheus-stack
because they need its CRDs.

A cron job writes `node_reboot_required` into node-exporter's textfile
collector directory, which the node-exporter DaemonSet mounts from the host.

Extra dashboards (Node Exporter Full 1860, Traefik 17347, cert-manager 11001)
are pinned by grafana.com ID and revision.

## Alert routing

| Match                 | Receiver   | Notes |
|-----------------------|------------|-------|
| `alertname=Watchdog`  | heartbeat  | Webhook to healthchecks.io every minute |
| `severity=none`       | null       | e.g. InfoInhibitor |
| everything else       | email      | Grouped by alertname and namespace, repeat 4h, send resolved |

The chart's default inhibit rules are kept: a critical alert silences its own
warning, and a warning silences its own info.

## Out of scope

Multi-node, HA control plane, off-server backups (S3 or Velero), volume
backups, log aggregation, GitOps.
