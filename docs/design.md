# Design: single-node k3s on a Contabo VPS

## Goal

Turn an existing Contabo VPS (Ubuntu 24.04) into a hardened, single-node
Kubernetes cluster with ingress, TLS, persistent storage and monitoring, from
one command, repeatably.

## Decisions

| Area        | Choice                                   | Why |
|-------------|------------------------------------------|-----|
| Provisioning| None, the VPS already exists             | Contabo VPSes are bought monthly; nothing to create |
| Config tool | Ansible                                  | Idempotent host configuration over SSH |
| Kubernetes  | k3s, pinned version                      | Small footprint, production ready, one binary |
| Ingress     | Traefik bundled with k3s                 | Already installed; ingress-nginx is retired (March 2026) |
| TLS         | cert-manager + Let's Encrypt HTTP-01     | Staging and prod ClusterIssuers |
| Storage     | k3s local-path + `local-path-retain` SC  | Longhorn cannot replicate on one node |
| Monitoring  | kube-prometheus-stack                    | Prometheus, Grafana, Alertmanager in one chart |
| Hardening   | sudo user, key-only SSH, UFW, fail2ban, unattended-upgrades | Baseline for a public VPS |

## Flow

1. `make bootstrap` connects as root, creates the admin user, proves that user
   can SSH in and sudo, and only then disables root and password login.
2. `make deploy` connects as the admin user and runs hardening, k3s and add-ons.
   Helm runs on the VPS against the local kubeconfig, so the only tools needed
   on the workstation are Ansible and its collections.
3. `make verify` checks the node is Ready, no pods are failing, the Grafana
   certificate is issued and Grafana answers over HTTPS.

## Firewall

- Public: 22 (rate limited), 80, 443
- 6443 (Kubernetes API): admin CIDRs only
- 10.42.0.0/16 and 10.43.0.0/16 (pod and service CIDRs): allowed, otherwise UFW
  drops in-cluster traffic

## k3s specifics

k3s runs the controller manager, scheduler and kube-proxy inside one process,
so kube-prometheus-stack's separate scrape jobs for them are disabled; they
would only fire false TargetDown alerts.

## Out of scope

Multi-node, HA control plane, backups (etcd snapshots or Velero), GitOps.
