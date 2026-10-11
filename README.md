# contabo-k8s

Ansible that turns a Contabo VPS running Ubuntu 24.04 into a hardened,
single-node [k3s](https://k3s.io) cluster with:

- Traefik ingress (bundled with k3s)
- cert-manager with Let's Encrypt staging and prod ClusterIssuers
- `local-path` and `local-path-retain` storage classes
- kube-prometheus-stack (Prometheus, Alertmanager, Grafana at `grafana.<domain>`)
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

## Setup

1. Set the VPS IP in `inventory/hosts.yml`.
2. Edit `group_vars/all/main.yml`: `domain`, `acme_email`, `admin_cidrs` (your
   public IP as `/32`, for `kubectl` access) and `admin_ssh_pubkey` if your key
   isn't `id_ed25519`.
3. Create the secrets vault:

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
make verify      # node Ready, pods healthy, Grafana cert issued, HTTPS up
```

`bootstrap` checks that the admin user can SSH in and sudo before it disables
root and password login. If that check fails, nothing is locked down.

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

Use `storageClassName: local-path-retain` for any data you don't want deleted
along with its PVC.

## Notes

- Set `cluster_issuer: letsencrypt-staging` while testing DNS, so you don't
  hit Let's Encrypt's production rate limits.
- Grafana stores its admin password in its database on first start. Changing
  `vault_grafana_admin_password` afterwards doesn't change it. Use
  `grafana-cli admin reset-admin-password` inside the pod.
- Unattended upgrades never reboot the server. Reboot during a quiet moment
  when `/var/run/reboot-required` exists.
- This is a single node with no backups. Before you store anything you can't
  lose, back up `/var/lib/rancher/k3s/server/db` and
  `/var/lib/rancher/k3s/storage`.
