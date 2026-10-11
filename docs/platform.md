# Shared platform

The `platform` role (`ansible-playbook site.yml --tags platform`) runs shared
services for apps on this cluster and gives each app a namespace, called a
tenant, wired up to them:

| Namespace | What runs there |
|-----------|-----------------|
| `databases` | One Postgres 16 server (CloudNativePG, 1 instance) and a nightly dump of every tenant database, kept for `pg_backup_retention_days` (7) |
| `storage` | One MinIO, with public files served read-only at `https://<assets_host>/<bucket>/<key>` |
| `cnpg-system` | The CloudNativePG operator |
| one per tenant | The tenant's Redis, its Secrets, and a deploy account for CI |

## Adding a tenant

Declare it in `group_vars/all/overrides.yml` (gitignored):

```yaml
tenants:
  - name: myapp-staging
    postgres: true          # a database and role named myapp_staging
    bucket: public-read     # or private; omit for no bucket
    registry_pull: true     # copy the GHCR pull token into this namespace
    hosts: [stg.example.com, stg-api.example.com]   # hostnames its Ingresses may use
```

App secrets go in the vault, keyed by tenant:

```sh
ansible-vault edit group_vars/all/vault.yml
```

```yaml
vault_tenant_secrets:
  myapp-staging:
    JWT_SECRET: ...
```

Then run `ansible-playbook site.yml --tags platform` and
`ansible-playbook verify.yml`. Re-running never rotates a password: generated
values are read back from the cluster.

## What a tenant gets

Secrets in the tenant namespace, ready for `envFrom`:

| Secret | Keys | Notes |
|--------|------|-------|
| `postgres` | `DATABASE_URL` | Own database only; TLS (`sslmode=require`) |
| `storage` | `ENDPOINT`, `ACCESS_KEY`, `SECRET_KEY`, `BUCKET`, `USE_SSL`, `PUBLIC_URL` | Load with `prefix: STORAGE_`. The key can only touch its own bucket |
| `redis` | `REDIS_URL` | Redis 7 in the namespace, AOF on, `noeviction` |
| `app` | whatever is under `vault_tenant_secrets.<tenant>` | Booleans are written as `"true"`/`"false"` |
| `ghcr-pull` | image pull secret | Only with `registry_pull: true` |

It also gets a `deployer` ServiceAccount, and a kubeconfig for it at
`deploy-kubeconfigs/<tenant>.yaml` on your machine, for CI. It can apply
Deployments, Services, ConfigMaps, Ingresses, Traefik Middlewares and Jobs in
its own namespace, read pods and logs, and nothing else.

## Isolation, and its limits

Enforced by the cluster, and checked by `verify.yml`:

- A tenant's role can't connect to another tenant's database, and its bucket
  key can't write to another bucket.
- Only namespaces labelled `postgres-access` / `storage-access` can reach
  Postgres / MinIO at all.
- Pods in a tenant namespace accept connections only from the same namespace,
  Traefik and Prometheus, so other tenants can't reach its Redis or apps.
- Tenant namespaces enforce the `restricted` Pod Security profile: no
  privileged pods, host mounts, host networking or host ports. Pods must run as
  non-root with `seccompProfile: RuntimeDefault`, no privilege escalation and
  all capabilities dropped.
- Services must be `ClusterIP` without `externalIPs`. NodePort and
  LoadBalancer ports would bypass UFW.
- Ingresses may only use the tenant's `hosts`, so one tenant can't take over
  another's (or Grafana's, or the assets host's) traffic or certificates.
- The public assets host answers only `GET` and `HEAD` for objects. It never
  routes MinIO's own `/minio/` paths.

Not enforced: the deploy account can't read Secrets through the API, but it
can create pods, and a pod can mount any Secret in its namespace. Treat a
tenant's CI credentials as able to read that tenant's secrets. They can't
reach other tenants' namespaces.

New pods get network access about two seconds after they start. Anything that
connects to Postgres or MinIO the moment it starts should retry.

## Day to day

Connect to Postgres from your machine:

```sh
kubectl -n databases port-forward svc/postgres-rw 5432 &
kubectl -n databases get secret tenant-<tenant> -o jsonpath='{.data.password}' | base64 -d
psql "postgres://<db>@localhost:5432/<db>?sslmode=require"
```

`<db>` is the tenant name with `-` replaced by `_`.

MinIO console: `kubectl -n storage port-forward svc/minio 9001`, then
http://localhost:9001 as `admin` with
`kubectl -n storage get secret minio-root -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 -d`.

Take a dump now: `kubectl -n databases create job --from=cronjob/pg-dump pg-dump-manual`.

## Restoring one database

Start a shell with the dumps mounted:

```sh
kubectl -n databases run pg-restore --rm -it --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:16.14-standard-trixie \
  --overrides='{"spec":{"securityContext":{"runAsUser":26},"containers":[{"name":"pg-restore",
    "image":"ghcr.io/cloudnative-pg/postgresql:16.14-standard-trixie","stdin":true,"tty":true,
    "command":["bash"],"env":[{"name":"PGHOST","value":"postgres-rw"},{"name":"PGSSLMODE","value":"require"}],
    "volumeMounts":[{"name":"dumps","mountPath":"/backups"}]}],
    "volumes":[{"name":"dumps","persistentVolumeClaim":{"claimName":"pg-dumps"}}]}}'
```

Inside it, as the tenant's own role (scale the app down first):

```sh
ls /backups/<db>
PGUSER=<db> PGPASSWORD=<tenant password> pg_restore --clean --if-exists --no-owner -d <db> /backups/<db>/<stamp>.dump
```

Dumps live on the same disk as the database. Copy them off the server before
you rely on them.

## Removing a tenant

Delete it from `tenants` and re-run. Nothing is deleted: the `Database`
resource retains the database, volumes use `local-path-retain`, and the
namespace stays. Remove those by hand once you're sure.
