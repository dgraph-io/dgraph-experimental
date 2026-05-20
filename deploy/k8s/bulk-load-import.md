# Bulk Load and Import into Kubernetes

Load data offline with `dgraph bulk`, then inject the output into a running k8s cluster. This is significantly faster than live loading for large datasets because the bulk loader builds Badger LSM trees directly, bypassing the mutation pipeline.

## Prerequisites

- A deployed Dgraph k8s cluster (see [README.md](README.md))
- `dgraph` binary on your local machine, **same version** as the cluster image
- RDF or JSON-LD data file(s) and a schema file
- `kubectl` pointed at the target cluster

## Overview

1. Deploy the cluster (or use an existing one)
2. Run `dgraph bulk` locally against the cluster's Zero
3. Scale down Alphas
4. Inject bulk output into Alpha PVCs via temporary pods
5. Scale Alphas back up
6. Verify

## Step 1: Deploy the cluster

Skip this if you already have a running cluster. The number of Alphas determines how many reduce shards to use.

**Local (Docker Desktop):**
```bash
cd deploy/k8s
./local-provision.sh -c sharded -e local --reset --image-tag <version>
```

**GKE:**
```bash
./gke-provision.sh create -p <project> -c sharded --image-tag <version>
```

Get the Zero gRPC endpoint:

```bash
# Local — read the NodePort
kubectl -n dgraph get svc dgraph-dgraph-zero \
  -o jsonpath='{.spec.ports[?(@.name=="grpc-zero")].nodePort}'

# GKE — port-forward
kubectl -n dgraph port-forward svc/dgraph-dgraph-zero 5080:5080 &
```

## Step 2: Run bulk load

The key flag is `--reduce_shards`, which must match the number of Alpha groups. For the sharded config (3 Alphas, each its own group), use 3.

```bash
mkdir -p /tmp/dgraph-bulk

dgraph bulk \
  -f <data-file.rdf.gz> \
  -s <schema-file> \
  --zero localhost:<ZERO_GRPC_PORT> \
  --reduce_shards=<NUM_ALPHA_GROUPS> \
  --map_shards=<NUM_ALPHA_GROUPS> \
  --out /tmp/dgraph-bulk/out
```

This produces one directory per shard:

```
out/
  0/p/    # group_id=1
  1/p/    # group_id=2
  2/p/    # group_id=3
```

Each `p/` directory is a self-contained Badger database ready for one Alpha.

### Example: 21M movie dataset (sharded, 3 groups)

```bash
dgraph bulk \
  -f dgraphtest/datafiles/21million.rdf.gz \
  -s dgraphtest/datafiles/21million.schema \
  --zero localhost:5080 \
  --reduce_shards=3 \
  --map_shards=3 \
  --out /tmp/dgraph-bulk/out
```

### Non-sharded config (1 group, 3 replicas)

When using `values-non-sharded.yaml`, all Alphas share one group. Use `--reduce_shards=1` and inject the same `out/0/p` into every Alpha.

## Step 3: Scale down Alphas

```bash
kubectl -n dgraph scale statefulset dgraph-dgraph-alpha --replicas=0
kubectl -n dgraph wait --for=delete pod -l app=dgraph-alpha --timeout=120s
```

PVCs remain bound and are not deleted.

## Step 4: Inject bulk output into Alpha PVCs

For each Alpha, create a temporary busybox pod that mounts its PVC, clear the existing data, and copy in the bulk output.

### Sharded (one shard per Alpha)

```bash
NS=dgraph
NUM_SHARDS=3  # must match --reduce_shards

for i in $(seq 0 $((NUM_SHARDS - 1))); do
  PVC="datadir-dgraph-dgraph-alpha-$i"

  # Create temp pod
  kubectl -n $NS run bulk-inject-$i --image=busybox --restart=Never \
    --overrides='{
      "spec": {
        "containers": [{
          "name": "inject",
          "image": "busybox",
          "command": ["sleep", "3600"],
          "volumeMounts": [{"name": "data", "mountPath": "/dgraph"}]
        }],
        "volumes": [{
          "name": "data",
          "persistentVolumeClaim": {"claimName": "'$PVC'"}
        }]
      }
    }'
  kubectl -n $NS wait --for=condition=Ready pod/bulk-inject-$i --timeout=60s

  # Clear old data and copy bulk output
  kubectl -n $NS exec bulk-inject-$i -- rm -rf /dgraph/p /dgraph/t /dgraph/w
  kubectl cp /tmp/dgraph-bulk/out/$i/p $NS/bulk-inject-$i:/dgraph/p

  # Verify
  kubectl -n $NS exec bulk-inject-$i -- cat /dgraph/p/group_id
  echo " <- expected group_id for shard $i"

  # Cleanup
  kubectl -n $NS delete pod bulk-inject-$i --force
done
```

### Non-sharded (same data on every Alpha)

```bash
# Same loop, but always copy out/0/p
kubectl cp /tmp/dgraph-bulk/out/0/p $NS/bulk-inject-$i:/dgraph/p
```

### Large datasets

`kubectl cp` can be slow for multi-GB directories. For large datasets, tar and pipe directly:

```bash
tar cf - -C /tmp/dgraph-bulk/out/$i p | \
  kubectl -n $NS exec -i bulk-inject-$i -- tar xf - -C /dgraph/
```

## Step 5: Scale Alphas back up

```bash
kubectl -n dgraph scale statefulset dgraph-dgraph-alpha --replicas=<NUM_ALPHAS>
kubectl -n dgraph rollout status statefulset/dgraph-dgraph-alpha --timeout=120s
```

## Step 6: Verify

```bash
# Health check
curl -s http://localhost:<ALPHA_HTTP_PORT>/health | jq '.[].status'

# Check predicate distribution across groups
curl -s http://localhost:<ZERO_HTTP_PORT>/state | \
  jq '.groups | to_entries[] | {group: .key, predicates: (.value.tablets | length)}'

# Query
curl -s http://localhost:<ALPHA_HTTP_PORT>/query -XPOST \
  -H "Content-Type: application/dql" \
  -d '{ q(func: has(name), first: 5) { name@en } }'
```

## Important notes

**Version matching.** The `dgraph bulk` binary and the cluster image must be the same version. Badger's on-disk format can change between releases. If versions differ, the Alphas may fail to open the `p` directory.

**Zero WAL and addressing.** The bulk loader connects to Zero to allocate timestamps. The Zero address used during bulk load is recorded in Zero's Raft WAL. If you later change Zero's `--my` address (e.g., moving from local to k8s FQDNs), the stale address will persist in the WAL. Dgraph v25.3.4+ includes automatic address reconciliation ([#9680](https://github.com/dgraph-io/dgraph/pull/9680)); on older versions, you must either ensure the bulk load Zero uses the same `--my` as production, or bootstrap Zero fresh and only inject the Alpha `p` directories.

**PVC naming convention.** The Helm chart names Alpha PVCs as `datadir-dgraph-<release>-alpha-<ordinal>`. If your Helm release name is not `dgraph`, adjust the PVC names accordingly.

**Non-sharded replication.** When injecting the same `out/0/p` into multiple Alphas in a single group, all replicas start with identical data. Raft will keep them in sync after startup.