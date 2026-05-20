# Dgraph Helm Deployment Scripts

Deploy Dgraph clusters locally (Docker Desktop) or on Google Kubernetes Engine (GKE).

## Prerequisites

- **kubectl** — [Install](https://kubernetes.io/docs/tasks/tools/)
- **helm** — [Install](https://helm.sh/docs/intro/install/)
- **For local:** A running local Kubernetes cluster (e.g. Docker Desktop with Kubernetes enabled — see [Local Setup](#local-docker-desktop-with-kubernetes) below)
- **For GKE:** `gcloud` CLI — [Install](https://cloud.google.com/sdk/docs/install)

## Quick Start

### Local (Docker Desktop with Kubernetes)

Before running the script, make sure you have a local Kubernetes cluster running and `kubectl` pointed at it. The simplest option is Docker Desktop's built-in Kubernetes:

1. Open **Docker Desktop → Settings → Kubernetes** and check **Enable Kubernetes**, then **Apply & Restart**.
2. Wait for the green "Kubernetes running" indicator in the Docker Desktop UI.
3. Verify from the terminal:
   ```bash
   kubectl config use-context docker-desktop
   kubectl cluster-info          # should return server URLs, not a connection error
   ```

If you prefer `kind`, `minikube`, or `k3d`, any of those work — just make sure `kubectl config current-context` points at a live cluster before running the script.

```bash
# Deploy sharded cluster (3 Alphas, 1 Zero, 3 groups)
./local-provision.sh -c sharded -e local

# Deploy non-sharded cluster (3 Alpha replicas, 1 Zero)
./local-provision.sh -c nonsharded -e local

# Fresh deploy (wipes existing PVCs)
./local-provision.sh -c sharded -e local --reset

# Export endpoints to shell (bash/zsh)
eval "$(./local-provision.sh -c sharded -e local --emit-env)"

# Export endpoints to shell (fish)
./local-provision.sh -c sharded -e local --emit-env --shell fish | source

echo $DGRAPH_ALPHA_HTTP_URL   # http://localhost:<nodeport>
echo $DGRAPH_ALPHA_GRPC_ADDR  # localhost:<nodeport>
```

### GKE (Google Kubernetes Engine)

You don't need an existing GCP project — `gcp-project-setup.sh create` makes one. You do need a Google account with permission to create projects (either standalone or under an org/folder) and an active billing account to link.

```bash
# 1. Authenticate with GCP (make sure you're on the right account)
gcloud auth login
gcloud auth list                       # verify the active account

# 2. Set up GCP project (first time only)
./gcp-project-setup.sh list-billing
./gcp-project-setup.sh create -p my-dgraph-bench -b <BILLING_ACCOUNT_ID>

# 3. Create cluster and deploy Dgraph
./gke-provision.sh create -p my-dgraph-bench -c sharded

# 4. Export endpoints (bash/zsh)
eval "$(./local-provision.sh -c sharded -e gke --emit-env)"

# Or for fish shell:
./local-provision.sh -c sharded -e gke --emit-env --shell fish | source
```

## Scripts

| Script | Purpose |
|--------|---------|
| `local-provision.sh` | Deploy Dgraph via Helm (works for both local and GKE) |
| `gke-provision.sh` | Create/teardown GKE clusters, then deploy Dgraph |
| `gcp-project-setup.sh` | Create GCP projects with billing and APIs enabled |

## Configurations

### Sharded (`values-sharded.yaml`)
- 1 Zero, 3 Alphas (each Alpha = 1 shard/group)
- Use for testing horizontal scaling and sharding behavior

### Non-Sharded (`values-non-sharded.yaml`)
- 1 Zero, 3 Alphas (all in single group with replication)
- Use for testing high availability without sharding

## Endpoints

After deployment, Dgraph exposes two ports on the Alpha service and two on the Zero service:

| Service | Port | Protocol | Use |
|---------|------|----------|-----|
| Alpha | 8080 | HTTP | GraphQL, Ratel UI, health checks |
| Alpha | 9080 | gRPC | dgo client, bulk operations |
| Zero  | 6080 | HTTP | Admin: `/state`, `/removeNode`, `/assign` |
| Zero  | 5080 | gRPC | Raft (used by Alphas; rarely needed externally) |

**Local (`-e local`):** Alpha and Zero both use NodePort — access via `localhost:<assigned-port>`. `--emit-env` exports:
- `DGRAPH_ALPHA_HTTP_URL`, `DGRAPH_ALPHA_GRPC_ADDR`
- `DGRAPH_ZERO_HTTP_URL`, `DGRAPH_ZERO_GRPC_ADDR`

**GKE (`-e gke`):** Alpha uses LoadBalancer — access via `<external-ip>:8080` and `<external-ip>:9080`. Zero stays ClusterIP (the admin API is sensitive and an extra LoadBalancer is ~$18/mo). Use `kubectl port-forward` to reach Zero — see [Accessing Zero on GKE](#accessing-zero-on-gke) below.

## GKE Options

### Cluster Configuration

```bash
./gke-provision.sh create -p <project> -c sharded \
  -z us-central1-a \          # Zone (default: us-central1-a)
  -m e2-standard-4 \          # Machine type (default: e2-standard-4)
  -N 3 \                      # Number of nodes (default: 3)
  --disk-size 100             # Boot disk GB (default: 100)
```

### Override Dgraph Image

By default the Helm chart pulls `dgraph/dgraph:latest` (see [values-sharded.yaml](deploy/k8s/values-sharded.yaml) / [values-non-sharded.yaml](deploy/k8s/values-non-sharded.yaml)). Override either field from the command line:

```bash
# Pin a specific version
./gke-provision.sh create -p my-project -c sharded --image-tag v24.0.5

# Use a custom repository + tag
./gke-provision.sh create -p my-project -c sharded \
  --image-repository my-registry/dgraph \
  --image-tag v24.0.5
```

The same flags work for `local-provision.sh`:
```bash
./local-provision.sh -c sharded -e local --image-tag v24.0.5
```

### Accessing Zero on GKE

Zero stays on a ClusterIP service for GKE deployments (avoids exposing the admin API publicly and saves the cost of an extra LoadBalancer). To reach it from your laptop, use `kubectl port-forward`:

```bash
# Forward Zero's HTTP admin port (6080) to localhost:6080
kubectl -n dgraph port-forward svc/dgraph-dgraph-zero 6080:6080

# In another terminal:
curl http://localhost:6080/state | jq

# Forward both admin (6080) and raft (5080) ports
kubectl -n dgraph port-forward svc/dgraph-dgraph-zero 6080:6080 5080:5080

# Forward to a specific pod instead of the service (useful for multi-Zero setups)
kubectl -n dgraph port-forward pod/dgraph-dgraph-zero-0 6080:6080
```

To run it in the background and clean up later:
```bash
kubectl -n dgraph port-forward svc/dgraph-dgraph-zero 6080:6080 &
PF_PID=$!

# ... do work ...

kill $PF_PID
```

Common Zero admin endpoints once forwarded:
- `GET  http://localhost:6080/state` — cluster state (groups, tablets, members)
- `GET  http://localhost:6080/health` — health check
- `POST http://localhost:6080/removeNode?id=<N>&group=<G>` — remove a dead node
- `GET  http://localhost:6080/assign?what=uids&num=1000` — pre-allocate UIDs

If you also need per-Alpha access on GKE (e.g. to test sharding behavior without going through the load balancer):

```bash
kubectl -n dgraph port-forward pod/dgraph-dgraph-alpha-0 18080:8080 19080:9080
kubectl -n dgraph port-forward pod/dgraph-dgraph-alpha-1 28080:8080 29080:9080
kubectl -n dgraph port-forward pod/dgraph-dgraph-alpha-2 38080:8080 39080:9080
```

### Restrict LoadBalancer Access

Limit access to your IP only:

```bash
./gke-provision.sh create -p my-project -c sharded \
  --lb-source-range "$(curl -s ifconfig.me)/32"
```

### Teardown

```bash
# Delete cluster
./gke-provision.sh teardown -p my-project

# Delete cluster AND orphaned disks
./gke-provision.sh teardown -p my-project --delete-disks
```

### Delete GCP Project

```bash
./gcp-project-setup.sh delete -p my-project
```

## Gotchas & Troubleshooting

### 1. `gke-gcloud-auth-plugin not found`

**Symptom:** kubectl commands fail with credential plugin error.

**Fix:**
```bash
gcloud components install gke-gcloud-auth-plugin
```

If gcloud is installed via Homebrew:
```bash
brew install --cask google-cloud-sdk
gcloud components install gke-gcloud-auth-plugin
```

### 2. SSD Quota Exceeded

**Symptom:** Pods stuck in `Pending`, PVCs show `QUOTA_EXCEEDED` for `SSD_TOTAL_GB`.

**Cause:** Default GCP quota is 500GB SSD per region. With 3 nodes × 100GB boot disks + PVCs, you hit the limit quickly.

**Fixes:**
- Reduce PVC size in values files (already set to `10Gi`)
- Reduce boot disk size: `--disk-size 50`
- Request quota increase: [GCP Quotas Console](https://console.cloud.google.com/iam-admin/quotas) → search "SSD_TOTAL_GB"

### 3. Billing Required for GKE

**Symptom:** Cannot create GKE cluster, API errors about billing.

**Fix:** Link a billing account when creating the project:
```bash
./gcp-project-setup.sh list-billing
./gcp-project-setup.sh create -p my-project -b <BILLING_ACCOUNT_ID>
```

### 4. Pods Stuck Waiting

**Debug steps:**
```bash
# Check pod status
kubectl get pods -n dgraph

# Check events for a stuck pod
kubectl describe pod <pod-name> -n dgraph | tail -30

# Check PVC status
kubectl get pvc -n dgraph

# Check PVC events
kubectl describe pvc <pvc-name> -n dgraph | tail -20
```

### 5. LoadBalancer IP Not Assigned

**Symptom:** External IP stays `<pending>`.

**Cause:** Usually quota or networking issues in GCP.

**Debug:**
```bash
kubectl get svc -n dgraph -w
kubectl describe svc dgraph-dgraph-alpha -n dgraph
```

## Cost Estimates (GKE)

Running 24/7 with defaults (`e2-standard-4`, 3 nodes, 100GB disks):

| Resource | Approximate Cost |
|----------|------------------|
| 3× e2-standard-4 VMs | ~$0.40/hr (~$290/mo) |
| Persistent disks | ~$50/mo |
| Load Balancer | ~$18/mo + egress |
| **Total** | **~$350-400/mo** |

**To minimize costs:**
- Teardown when not in use: `./gke-provision.sh teardown -p <project>`
- Use smaller machines: `-m e2-small`
- Use fewer nodes: `-N 1`

## Using with dgo (Go gRPC Client)

```go
import (
    "github.com/dgraph-io/dgo/v210"
    "github.com/dgraph-io/dgo/v210/protos/api"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
)

conn, err := grpc.Dial(
    os.Getenv("DGRAPH_ALPHA_GRPC_ADDR"),  // e.g., "35.223.2.31:9080"
    grpc.WithTransportCredentials(insecure.NewCredentials()),
)
if err != nil {
    log.Fatal(err)
}
defer conn.Close()

client := dgo.NewDgraphClient(api.NewDgraphClient(conn))
```
