# Cluster Setup

> This document describes how the environment this suite runs against was
> built, using the values files in this repository. It's provided as a
> reference for setting up your own dual-region environment to run against
> — see the disclaimer in [README.md](README.md): this is not a production
> deployment guide, and every step below should be reviewed and adapted to
> your own infrastructure, security requirements, and Camunda license
> before use.

This assumes two separate Kubernetes/OpenShift clusters already exist — one
per region — with `oc`/`kubectl` access configured for each.

## 1. Cross-cluster connectivity

Both regions' Zeebe brokers need to reach each other directly (for Raft
replication), and both regions' Keycloak need to reach the shared Postgres
instance in step 3. This suite was built using
[Submariner](https://submariner.io/), which provides this via a
`clusterset.local` DNS domain resolvable from either cluster.

```bash
# On whichever cluster you designate as the broker:
subctl deploy-broker

# On each cluster (including the broker cluster itself), with a distinct
# --clusterid per cluster:
subctl join --clusterid east broker-info.subm
subctl join --clusterid west broker-info.subm

# Verify both clusters see each other:
subctl show connections
subctl show gateways
```

Any other cross-cluster networking solution that provides equivalent
service-to-service DNS resolution between the two clusters can be
substituted — the values files in this repository only depend on a
resolvable `<service>.<namespace>.svc.clusterset.local` style hostname, not
on Submariner specifically.

## 2. Object storage (MinIO) per region, with bucket replication

Each region needs its own S3-compatible object store, used both as
Elasticsearch's snapshot target and as the storage backend the two regions
replicate between for cross-region backup/restore. This suite was built
against a single-instance MinIO deployment per region (a `Deployment` +
`PersistentVolumeClaim` + `Service`, not MinIO's distributed mode - fine for
a test environment, reconsider for anything larger).

For each region:

```bash
# Create the bucket
mc alias set local http://<minio-service>:9000 <access-key> <secret-key>
mc mb local/camunda-dr-backup
```

Then configure **bidirectional** bucket replication between the two
regions' MinIO instances (adapt the endpoints/credentials to your setup):

```bash
# On east's MinIO, add west as a replication target, and vice versa
mc admin bucket remote add local/camunda-dr-backup \
  http://<access-key>:<secret-key>@<west-minio-endpoint>:9000/camunda-dr-backup --service replication
mc replicate add local/camunda-dr-backup --remote-bucket <arn-from-previous-command>

# Repeat in the other direction, on west's MinIO, targeting east
```

Verify replication is healthy from either side:

```bash
mc replicate status local/camunda-dr-backup
```

You should see `Link: ● online` and `Errors: 0` in both directions before
proceeding. Elasticsearch's own snapshot repository registration (pointing
at this bucket) is handled automatically by the test scripts at runtime —
see the [README](README.md#design-notes) for why that registration itself
can't be a one-time, declarative step.

## 3. Standalone, always-on PostgreSQL for Keycloak

Rather than letting Keycloak's bundled per-region Postgres subchart get torn
down every time a region is demoted, this suite uses one standalone
Postgres release, installed independently of the main Camunda Helm release,
living permanently in one region (East, in this reference setup) and
reachable from both.

```bash
# In east's cluster/namespace:
helm upgrade --install keycloak-postgres bitnami/postgresql \
  --version 15.5.38 \
  --set fullnameOverride=keycloak-postgres \
  --set image.repository=bitnamilegacy/postgresql \
  --set volumePermissions.image.repository=bitnamilegacy/os-shell \
  --set metrics.image.repository=bitnamilegacy/postgres-exporter \
  --set auth.existingSecret=camunda-credentials \
  --set auth.secretKeys.adminPasswordKey=identity-keycloak-postgresql-admin-password \
  --set auth.secretKeys.userPasswordKey=identity-keycloak-postgresql-user-password \
  --set auth.username=bn_keycloak \
  --set auth.database=bitnami_keycloak \
  --set primary.persistence.size=8Gi
```

(The `bitnamilegacy/*` image overrides are needed because Bitnami moved
older free-tier image tags to that registry; adjust if using a different
registry or a paid Bitnami/Tanzu subscription.)

Export its Service so the other region can reach it over the
`clusterset.local` DNS domain from step 1:

```yaml
# keycloak-postgres-serviceexport.yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata:
  name: keycloak-postgres
  namespace: <east-namespace>
```

```bash
oc --context <east-context> apply -f keycloak-postgres-serviceexport.yaml
```

`helm-overlays/test-d/{east,west}-values.yaml` both point their
`identityKeycloak.externalDatabase.host` at this instance via its
`clusterset.local` hostname — update that value if you install it under a
different namespace/release name.

**Accepted trade-off**: since this Postgres lives in one region only, a
genuine (not simulated) loss of that region takes Keycloak down in both
regions, since the database goes with it. This is a deliberate simplification
for a two-cluster test environment, not a recommendation for production
(which would use a properly replicated/managed Postgres instead).

## 4. The `camunda-credentials` Secret

Every credential this suite's Helm values reference comes from one Secret,
`camunda-credentials`, in each region's namespace — with one documented
exception (`orchestration.security.initialization.users[].password`, a
Camunda Helm chart limitation, covered by `helm-overlays/orchestration-users.yaml`
instead; see the main [README](README.md#configuration)).

Create an empty Secret in each region first:

```bash
oc --context <context> -n <namespace> create secret generic camunda-credentials
```

`promote-region-d.sh` / `demote-region-d.sh` automatically generate and
populate any missing per-region keys (Identity/WebModeler database
passwords, migration client secret, etc.) into this Secret the first time
each region is promoted — you do not need to pre-populate those yourself.
The one exception is the shared Keycloak database credentials
(`identity-keycloak-admin-password`,
`identity-keycloak-postgresql-admin-password`,
`identity-keycloak-postgresql-user-password`), which must be **identical**
in both regions' Secrets, since both regions authenticate against the same
standalone Postgres from step 3. `ensure_shared_keycloak_db_secret` (in
`scripts/lib/common.sh`) keeps these in sync automatically on every
promotion, copying a value from whichever region already has one, or
generating a fresh value and writing it to both regions if neither does.

## 5. Deploy Camunda 8 in both regions

With the above in place, install Camunda in each region using this
repository's values files. East starts active, West starts passive:

```bash
# East (active)
helm --kube-context <east-context> -n <east-namespace> install camunda camunda/camunda-platform \
  --version 13.11.1 \
  -f helm-overlays/test-d/east-values.yaml \
  -f helm-overlays/test-d/active-overlay.yaml \
  -f helm-overlays/orchestration-users.yaml \
  --timeout 10m

# West (passive)
helm --kube-context <west-context> -n <west-namespace> install camunda camunda/camunda-platform \
  --version 13.11.1 \
  -f helm-overlays/test-d/west-values.yaml \
  -f helm-overlays/test-d/passive-overlay.yaml \
  -f helm-overlays/orchestration-users.yaml \
  --timeout 10m
```

Both values files reference several `clusterset.local` hostnames baked in
for this reference setup's namespace names
(`ZEEBE_BROKER_CLUSTER_INITIALCONTACTPOINTS`, the exporter connect URLs, the
advertised host, and the Keycloak `externalDatabase.host`) — update every
occurrence of the example namespace names to match your own before
installing.

After the initial install, all subsequent promotions/demotions between
active and passive should go through `promote-region-d.sh` /
`demote-region-d.sh` (or the equivalent step scripts), not raw `helm
install` — those scripts handle the Secret population from step 4 and the
Keycloak realm/user provisioning that a bare Helm install doesn't cover.

## 6. Verify

```bash
oc --context <east-context> -n <east-namespace> get pods
oc --context <west-context> -n <west-namespace> get pods
./scripts/leadership-distribution.sh
```

You should see all 8 Zeebe broker pods (4 per region) `Running`, partition
leadership split across both regions, East showing Identity/Keycloak/
Optimize/Connectors, and West showing Identity/Keycloak/Optimize only
(Connectors scaled to 0). Once this is healthy, you're ready to run
`./scripts/reset-cluster-d.sh` and start the test scenario from the main
[README](README.md#quick-start).
