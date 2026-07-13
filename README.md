# Dual-Region Automated Failover Testing

> **Disclaimer**: this repository is provided as a **reference implementation** of how backup, restore, failover, and failback can be performed and verified in a dual-region Camunda 8 deployment. It is **not intended for production use**. It has only been exercised against disposable test clusters, and does not carry any guarantee of correctness, security hardening, or fitness for a production environment. Review, adapt, and test thoroughly against your own environment and requirements before using any part of it beyond this reference purpose.

Automated disaster-recovery test suite for a dual-region [Camunda 8](https://camunda.com/platform/) deployment. It scripts a full, repeatable failure-and-recovery cycle across two regions — East (primary) and West (secondary) — and verifies at every stage that data, engine state, and identity/authorization data all survive correctly.

This suite is built around one core guarantee — **Zeebe is never restarted** by promoting or demoting a region. Every other component (Identity, Keycloak, Optimize) runs active-active across both regions permanently; only Connectors is genuinely toggled active/passive. This removes the operational risk of an unrelated administrative action (promoting a region) triggering a disruptive rolling restart of the Zeebe cluster.

## What this suite verifies

Running end-to-end, the suite proves:

1. **Zeebe failover**: when East's Zeebe brokers become unreachable, West's cluster recovers quorum via a force-remove of the dead brokers, with zero data loss.
2. **Continuity of service**: process data created and read during the outage is served correctly by the surviving region.
3. **Backup and restore**: an Elasticsearch snapshot taken from the surviving region is restored into the recreated region via MinIO's cross-region bucket replication.
4. **Zero unnecessary restarts**: Zeebe broker pods are never recreated by any promote/demote operation — only by the deliberate PVC wipe that simulates total region loss.
5. **Engine-level recovery**: a pre-outage process instance can still be completed after recovery, proving the underlying RocksDB/Raft engine state — not just the Elasticsearch projection of it — survived intact.
6. **Partition leadership rebalancing**: after failback, partition leadership (which settles entirely on the surviving region during the outage) is actively rebalanced back across both regions.
7. **Identity/Keycloak architecture**: a Keycloak user and role created through one region during the outage are visible through the other region after failback, proving both regions genuinely share one Keycloak realm and database rather than two independent instances that merely look alike.

## Architecture assumptions

This suite expects an already-running dual-region Camunda 8 environment with the following shape:

- Two Kubernetes/OpenShift clusters, one per region, with cross-cluster service connectivity (e.g. via [Submariner](https://submariner.io/)) so each region can reach the other's Zeebe brokers and Elasticsearch.
- Camunda 8 deployed via Helm in both regions, using the values files in `helm-overlays/test/` (see [Configuration](#configuration) below) — Zeebe with a replication factor spanning both regions, Identity/Keycloak/Optimize active-active, Connectors active-passive.
- A single, standalone, always-on PostgreSQL instance for Keycloak, living in one region as its own Helm release (separate from the main Camunda release), reachable from both regions. Both regions' Keycloak point at this one database, so realm/user state survives every failover and failback. (This is the deliberate trade-off documented in `helm-overlays/test/east-values.yaml` — if that region is ever genuinely lost, not just simulated, Keycloak cannot come up in the other region either, since its database goes with it.)
- One S3-compatible object store per region (e.g. [MinIO](https://min.io/)), each with a bucket already created, configured with **bidirectional bucket replication** between the two regions. Snapshots taken from either region's Elasticsearch become visible to the other automatically.
- A Zeebe test process deployed with a basic-auth user provisioned (see [Prerequisites](#prerequisites)).

## Repository layout

```
scripts/
  test/                        Step 00-08: the test scenario itself
  promote-region.sh            Promotes a region to active (toggles Connectors only)
  demote-region.sh             Demotes a region to passive (toggles Connectors only)
  reset-cluster.sh             Resets both regions to a clean baseline before a run
  verify-partition-leaders.sh  Read-only: reports Zeebe partition leadership for one region
  leadership-distribution.sh   Read-only: reports partition leadership across both regions
  rebalance-partitions.sh      Actively rebalances partition leadership across both regions
  lib/                         Shared shell helpers and Python table/JSON formatters
  assets/test-process.bpmn     The BPMN process used to generate test data

helm-overlays/
  test/                        Per-region Helm values and active/passive overlays
  orchestration-users.yaml     Zeebe/Operate/Tasklist basic-auth users (shared, non-secret)
```

## Prerequisites

Before running anything:

1. **Cluster access** — `oc` (or `kubectl`) configured with a context for each region. Update the context names and namespaces at the top of `scripts/lib/common.sh` (`CONTEXT_EAST`, `NS_EAST`, `CONTEXT_WEST`, `NS_WEST`) to match your environment.
2. **Camunda already deployed** in both regions using `helm-overlays/test/{east,west}-values.yaml` plus the matching `active-overlay.yaml`/`passive-overlay.yaml`, with all real credentials supplied via the `camunda-credentials` Kubernetes Secret referenced throughout those values files — nothing in this repository contains literal secret values. See [CLUSTER_SETUP.md](CLUSTER_SETUP.md) for a full walkthrough of setting this up from scratch, including cross-cluster connectivity, MinIO replication, and the standalone Keycloak Postgres.
3. **A basic-auth test user** provisioned in Zeebe/Operate/Tasklist (username/password configured via `AUTH_USER`/`AUTH_PASS` in `scripts/lib/common.sh`).
4. **MinIO buckets already created** in both regions with bucket replication configured between them (see [CLUSTER_SETUP.md](CLUSTER_SETUP.md#2-object-storage-minio-per-region-with-bucket-replication)). Elasticsearch's own snapshot repository registration is handled by the scripts, but bucket creation itself is an Elasticsearch/object-storage-level action outside this project's scope.
5. **Command-line tools**: `oc` or `kubectl`, `helm`, `curl`, `python3` (used only for JSON parsing/table formatting, no third-party packages required).

## Quick start

Every command below is run from the repository root.

```bash
# 1. Reset both regions to a clean baseline (east active, west passive).
#    This is destructive: it wipes and rebuilds both regions' Elasticsearch and
#    Zeebe storage. Only run this against a disposable test environment.
./scripts/reset-cluster.sh

# 2. Run the scenario end-to-end, one step at a time.
./scripts/test/00-baseline.sh                    # create baseline process data
./scripts/test/01-inject-failure.sh              # simulate total loss of east
./scripts/test/02-verify-degraded.sh             # confirm west lost quorum
./scripts/test/03-failover.sh                    # force-remove east's brokers, promote west
./scripts/test/04-verify-existing-data.sh        # confirm baseline data is still served
./scripts/test/05-create-data-during-outage.sh   # create new data + a Keycloak user/role via west
./scripts/test/06-failback.sh                    # rebuild east, restore from west's backup, promote east
./scripts/test/07-check-leadership.sh            # rebalance partition leadership across both regions
./scripts/test/08-verify-final.sh                # final verification, including the Keycloak architecture proof
```

Each step prints the exact underlying `oc`/`curl`/`helm` command it runs before executing it, so the output doubles as a reference for how to perform each action manually if needed. State (which process instance keys were created, etc.) is passed between steps via `scripts/.state/test.env`, which is regenerated on every fresh run.

### Read-only checks

These can be run at any time, independent of the step sequence above, to inspect cluster state without changing anything:

```bash
./scripts/verify-partition-leaders.sh east   # or west
./scripts/leadership-distribution.sh         # both regions in one table
```

### Manually influencing partition leadership

`rebalance-partitions.sh` (used internally by `test/07-check-leadership.sh`) can be run standalone at any time to nudge Zeebe's partition leadership back toward an even split across both regions — useful after any operation that leaves leadership concentrated on one side and never triggers its own rebalance.

```bash
./scripts/rebalance-partitions.sh east
```

## Configuration

All environment-specific values live in two places:

- **`scripts/lib/common.sh`** — cluster contexts, namespaces, test-user credentials, and the BPMN process file used to generate data. Every other script sources this file.
- **`helm-overlays/test/*.yaml`** — the Helm values and overlays applied by `promote-region.sh`/`demote-region.sh`. Every credential referenced here is a Kubernetes Secret key reference (`secretKeyRef`), never a literal value, with one documented exception: `orchestration.security.initialization.users[].password` is rendered as plaintext into a ConfigMap by the Camunda Helm chart regardless of how it's supplied — a chart limitation, not a choice made by this project — which is why `helm-overlays/orchestration-users.yaml` is checked in as a plain values file rather than a secret reference.

## Design notes

- **Why Zeebe never restarts**: in this chart's consolidated pod model, the Zeebe broker, Operate, and Tasklist all run in the same StatefulSet. Toggling `orchestration.profiles.operate`/`tasklist` — even alone — forces a Kubernetes pod-template change and rolls every broker. This suite's values files bake these permanently on in both regions instead of toggling them, so promoting or demoting a region only ever touches Connectors, a completely separate Deployment with no effect on the Zeebe StatefulSet. Zeebe cluster membership itself changes only through the raw Zeebe actuator API (force-remove/add brokers), never through a Helm upgrade — see the [Management API docs](https://docs.camunda.io/docs/self-managed/components/orchestration-cluster/zeebe/operations/management-api/).
- **Why a full Zeebe PVC wipe on recovery**: restoring true quorum and replication factor after a broker loss requires a genuinely fresh bootstrap, not just a restart — a broker rejoining with stale storage cannot safely resume as a full member of the partition it was force-removed from. This mirrors the recovery approach described in the official [dual-region operational procedure](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/dual-region-operational-procedure/).
- **Why the index deletion step before restoring**: Zeebe's own exporter (the [`CamundaExporter`](https://docs.camunda.io/docs/next/self-managed/components/orchestration-cluster/zeebe/exporters/camunda-exporter/), running as a plugin inside each broker process) initializes its Elasticsearch index schema as soon as a broker starts, independent of whether it has rejoined the cluster topology yet. Those empty, schema-only indices conflict with restoring a snapshot over them, so they are deleted immediately beforehand. See also the official [backup and restore](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/backup-and-restore/) and [restore a backup](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/restore/) guides for the general snapshot/restore mechanics this automates.
- **Why partition leadership needs an explicit rebalance step**: Zeebe does not automatically move partition leadership back after a broker rejoins the cluster — see [Rebalancing](https://docs.camunda.io/docs/self-managed/components/orchestration-cluster/zeebe/operations/rebalancing/) and [Priority election](https://docs.camunda.io/docs/self-managed/zeebe-deployment/configuration/priority-election/) for the `/actuator/rebalance` endpoint `rebalance-partitions.sh` calls and the priority-election mechanism it depends on.

## References

- [Dual-region operational procedure – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/deployment/helm/operational-tasks/dual-region-operational-procedure/) — the official procedure this suite automates and verifies.
- [Camunda back up and restore – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/backup-and-restore/)
- [Restore a backup – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/operational-guides/backup-restore/restore/)
- [Camunda Exporter – Camunda 8 Docs](https://docs.camunda.io/docs/next/self-managed/components/orchestration-cluster/zeebe/exporters/camunda-exporter/)
- [Management API – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/components/orchestration-cluster/zeebe/operations/management-api/) — the actuator endpoints used for broker force-remove/add, exporter pause/resume, and rebalancing.
- [Rebalancing – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/components/orchestration-cluster/zeebe/operations/rebalancing/)
- [Priority election – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/zeebe-deployment/configuration/priority-election/)
- [Elasticsearch and OpenSearch – Camunda 8 Docs](https://docs.camunda.io/docs/self-managed/components/orchestration-cluster/core-settings/concepts/elasticsearch-and-opensearch/)
- [Camunda Helm chart repository](https://github.com/camunda/camunda-platform-helm)
- [Submariner documentation](https://submariner.io/) — the cross-cluster connectivity solution used in this reference setup.
- [MinIO documentation](https://min.io/docs/minio/linux/index.html) — bucket replication and the `mc` client used in [CLUSTER_SETUP.md](CLUSTER_SETUP.md).
