# contabo-k8s

Ansible that turns a Contabo VPS running Ubuntu 24.04 into a hardened,
single-node [k3s](https://k3s.io) cluster with:

- Traefik ingress (bundled with k3s), with HTTP redirected to HTTPS
- cert-manager with Let's Encrypt staging and prod ClusterIssuers
- `local-path` and `local-path-retain` storage classes
- kube-prometheus-stack: Prometheus, Grafana at `grafana.<domain>`, and
  Alertmanager sending email
- A healthchecks.io heartbeat that tells you when the whole server goes quiet
- etcd snapshots every 6 hours, kept for 7 days
- A sudo admin user, key-only SSH, UFW, fail2ban and unattended upgrades

See [docs/design.md](docs/design.md) for the reasoning behind each choice.

## Requirements

On your workstation:

- Ansible (`brew install ansible`), plus `make deps` for the collections
- An SSH key pair, `~/.ssh/id_ed25519` by default

Outside this repo:

- A DNS A record for `grafana.<domain>` pointing at the VPS
- Root SSH access by key. If you only have the Contabo root password, run
  `ssh-copy-id root@<vps-ip>` once.
- SMTP credentials for alert email. With Gmail, create an
  [app password](https://myaccount.google.com/apppasswords).
- A free [healthchecks.io](https://healthchecks.io) check with period 5 minutes
  and grace 5 minutes. Copy its ping URL.

## Setup

1. Put the VPS IP in `host_vars/k8s.yml` as `ansible_host: <ip>`.
2. Put your real values in `group_vars/all/overrides.yml`, which overrides
   `main.yml`:
   - `domain` and `acme_email`
   - `admin_cidrs`: your public IP as `/32`, for `kubectl` access
   - `admin_ssh_pubkey` if your key isn't `id_ed25519`
   - `alert_email_to`, `smtp_smarthost` and `smtp_username`
   - `tenants`, once you use the shared platform

   Both files are gitignored, so the repo can stay public: `main.yml` and
   `inventory/hosts.yml` keep placeholders.
3. Create the secrets vault with the Grafana password, SMTP password and
   healthchecks.io ping URL:

   ```sh
   ansible-vault create group_vars/all/vault.yml   # contents: see vault.yml.example
   ```

   To skip the password prompt, put the vault password in `.vault-pass`
   (gitignored).

## Deploy

```sh
make deps        # install Ansible collections
make bootstrap   # first run only, as root: admin user, SSH lockdown, firewall
make deploy      # as the admin user: hardening, k3s, add-ons
make verify      # smoke tests, listed below
```

`bootstrap` checks that the admin user can SSH in and sudo before it disables
root and password login. If that check fails, nothing is locked down.

`verify` checks that the node is Ready, no pods are failing, every Prometheus
target is up (including Traefik and cert-manager), the Grafana certificate is
issued, Grafana answers over HTTPS and plain HTTP redirects to HTTPS.

All runs are idempotent. Change a version or setting in `main.yml`, then run
`make deploy` again. `make check` does a dry run, which is only meaningful
after the first deploy.

## Using the cluster

`make deploy` writes `./kubeconfig` (gitignored), with the context named `contabo`:

```sh
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

The API on port 6443 only accepts connections from `admin_cidrs`. If your IP
changes, update the list and run `ansible-playbook site.yml --tags hardening`.

To expose an app with TLS, give its Ingress:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts: [app.example.com]
      secretName: app-tls
```

Expose apps through an Ingress and a ClusterIP Service. **Don't use `NodePort`
or `hostPort` services.** k3s writes iptables rules ahead of UFW, so those ports
are reachable from the internet whatever the firewall says.

Use `storageClassName: local-path-retain` for any data you don't want deleted
along with its PVC.

## Monitoring and alerts

Grafana is at `https://grafana.<domain>`. Log in as `admin` with the vault
password. Useful dashboards:

- **Server → Node Exporter Full**: everything about the VPS (CPU, memory,
  disk, network, systemd)
- **Node Exporter / Nodes** and **Node Exporter / USE Method / Node**: quick
  server health
- **Server → Traefik**: requests, latency and errors per service
- **Server → cert-manager**: certificate expiry and ACME activity
- **Kubernetes / Compute Resources / ...**: usage per namespace, workload and pod

Alerts are emailed to `alert_email_to`, grouped by alert name and namespace.
An alert is sent again every 4 hours while it's still firing, and once more
when it resolves. Besides the chart's built-in rules (disk filling up, memory,
CPU, failed systemd units, crash-looping pods, clock drift and more), this repo
adds:

| Alert                     | Fires when |
|---------------------------|------------|
| `CertificateExpiringSoon` | A certificate has under 14 days left, meaning renewal is failing |
| `CertificateNotReady`     | A certificate has been not Ready for 15 minutes |
| `TraefikHighErrorRate`    | A service returns over 5% 5xx responses for 10 minutes |
| `NodeRebootRequired`      | An update has needed a reboot for over a day |

Prometheus runs on the server it watches, so it can't report its own outage.
The always-firing `Watchdog` alert pings healthchecks.io every minute instead.
If the pings stop because the VPS, k3s, Prometheus or Alertmanager is down,
healthchecks.io emails you.

To check that email delivery works, send a test alert:

```sh
kubectl -n monitoring exec alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- \
  amtool alert add TestAlert severity=warning --alertmanager.url=http://localhost:9093
```

Prometheus, Alertmanager and their UIs aren't exposed publicly. Reach them with
`kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090`
(or `...-alertmanager 9093`).

## Backups

k3s uses embedded etcd and snapshots it every 6 hours, keeping 28 (7 days) in
`/var/lib/rancher/k3s/server/db/snapshots`. They cover cluster state: every
Kubernetes object, including Secrets. They **don't** cover volume data in
`/var/lib/rancher/k3s/storage`, and they live on the same disk, so they protect
against mistakes, not against losing the server.

```sh
sudo k3s etcd-snapshot ls                 # list snapshots
sudo k3s etcd-snapshot save --name manual # take one now
```

To restore:

```sh
sudo systemctl stop k3s
sudo k3s server --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot>
sudo systemctl start k3s
```

Copy snapshots off the server, or add S3 upload with k3s's `etcd-s3` options,
before you depend on them.

## Notes

- Set `cluster_issuer: letsencrypt-staging` while testing DNS, so you don't
  hit Let's Encrypt's production rate limits.
- Grafana stores its admin password in its database on first start. Changing
  `vault_grafana_admin_password` afterwards doesn't change it. Use
  `grafana-cli admin reset-admin-password` inside the pod.
- Unattended upgrades never reboot the server. `NodeRebootRequired` tells you
  when to do it yourself.
