# Dgraph on Kubernetes with kind

This directory contains scripts and configurations to set up a highly available Dgraph cluster on Kubernetes using [kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker). This setup is ideal for local development and testing, providing a production-like multi-node Kubernetes environment without cloud costs.

## What This Setup Does

The `setup.sh` script automates the complete setup process:

1. **Creates local data directories** on your host machine (`~/dgraph-data/alpha-{0,1,2}`)
2. **Recreates a kind cluster** with 1 control plane node and 3 worker nodes
3. **Mounts host directories** into all worker nodes for persistent storage
4. **Creates a StorageClass** (`local-storage`) for local persistent volumes
5. **Generates PersistentVolumes** that map to specific host directories
6. **Installs Dgraph** using Helm with high availability configuration
7. **Verifies the installation** by checking pod distribution, PVC bindings, and data directories

## Cluster Architecture

This setup creates a **highly available Dgraph cluster** with:

- **1 control plane node** - Manages the Kubernetes cluster
- **3 worker nodes** - Run Dgraph workloads
- **3 Dgraph Zero pods** - One per worker node (cluster coordination)
- **3 Dgraph Alpha pods** - One per worker node (data storage and queries)

Each worker node runs exactly one Zero and one Alpha pod, ensuring high availability while maximizing resource efficiency.

### Storage Architecture

For local development, data is mapped from your host machine to the kind cluster:

```
Host Machine (Mac/Linux)          kind Worker Nodes          Dgraph Pods
─────────────────────────          ──────────────────         ────────────
$HOME/dgraph-data/                 /dgraph-data/              /dgraph/
  ├── alpha-0/  ──────────────────>  ├── alpha-0/  ─────────>  alpha-0 pod
  ├── alpha-1/  ──────────────────>  ├── alpha-1/  ─────────>  alpha-1 pod
  └── alpha-2/  ──────────────────>  └── alpha-2/  ─────────>  alpha-2 pod
```

This allows you to directly inspect and experiment with Dgraph's data files, including the `p` folders (posting lists).

### Key Benefits

- **High Availability**: Each Zero and Alpha pod runs on a different node, ensuring fault tolerance
- **Resource Efficiency**: Uses only 3 nodes instead of 6, with one Zero and one Alpha per node
- **Production-Like**: Multi-node setup closely simulates real Kubernetes environments
- **Local Development**: Perfect for testing and development without cloud costs
- **Data Persistence**: Persistent storage ensures data survives pod restarts
- **Direct Data Access**: Local disk mapping allows direct inspection and experimentation with data files

## Prerequisites

Before running the setup, ensure you have the following tools installed:

- **Docker** - Running and accessible
- **kubectl** - Kubernetes command-line tool
- **Helm** - Kubernetes package manager
- **kind** - Kubernetes in Docker

### Install Prerequisites

On macOS, you can install these tools using Homebrew:

```bash
brew install kind kubectl helm
```

Verify your installations:

```bash
docker --version
kubectl version --client
helm version
kind --version
```

## Quick Start

Run the setup script with default values:

```bash
./setup.sh
```

Or specify custom values:

```bash
./setup.sh <release-name> [namespace] [host-data-path]
```

**Example:**
```bash
./setup.sh my-dgraph default ~/my-dgraph-data
```

**Default values:**
- Release name: `hatest`
- Namespace: `default`
- Host data path: `~/dgraph-data`

## Files Overview

| File | Purpose |
|------|---------|
| `setup.sh` | Main setup script that automates the entire process |
| `kind-cluster-config.yaml` | Generated kind cluster configuration with volume mounts |
| `kind-config.yaml` | Alternative kind cluster configuration |
| `my-values.yaml` | Helm values for Dgraph installation (3 Alpha replicas, local storage) |
| `local-storage-class.yaml` | StorageClass definition for local persistent volumes |
| `dgraph-alpha-pvs.yaml` | Generated PersistentVolumes for Alpha pods |
| `pvs.yaml` | Alternative PersistentVolume definitions |
| `create-storageclass.sh` | Standalone script to create the StorageClass |

## Common Commands

### kind Commands

#### Create Cluster
```bash
# Using the generated config
kind create cluster --config kind-cluster-config.yaml

# Or using the alternative config
kind create cluster --config kind-config.yaml
```

#### List Clusters
```bash
kind get clusters
```

#### Get Cluster Info
```bash
kind get kubeconfig
```

#### Stop Cluster (Preserves Data)
```bash
# Stop all kind containers
docker stop $(docker ps -q --filter "name=kind")

# Or stop specific cluster
docker stop kind-control-plane kind-worker kind-worker2 kind-worker3
```

#### Start Cluster
```bash
# Start all kind containers
docker start $(docker ps -a -q --filter "name=kind")

# Or start specific cluster
docker start kind-control-plane kind-worker kind-worker2 kind-worker3
```

After starting, verify nodes are ready:
```bash
kubectl get nodes
```

All nodes should show `STATUS: Ready` after a few moments.

#### Restart Cluster
```bash
# Stop and start
docker stop $(docker ps -q --filter "name=kind")
docker start $(docker ps -a -q --filter "name=kind")

# Wait for nodes to be ready
kubectl wait --for=condition=Ready nodes --all --timeout=120s
```

#### Delete Cluster
```bash
# Delete the default cluster
kind delete cluster

# Delete a specific cluster by name
kind delete cluster --name <cluster-name>
```

**Note:** Deleting the cluster removes all Kubernetes resources, but your data directories on the host remain. To remove them:

```bash
rm -rf ~/dgraph-data/alpha-*
```

### Docker Commands

#### View kind Containers
```bash
# List all kind containers
docker ps --filter "name=kind"

# List all kind containers (including stopped)
docker ps -a --filter "name=kind"
```

#### Inspect kind Containers
```bash
# Inspect a specific node
docker inspect kind-control-plane

# View logs from a node
docker logs kind-control-plane
```

#### Access kind Node Shell
```bash
# Access control plane node
docker exec -it kind-control-plane /bin/bash

# Access worker node
docker exec -it kind-worker /bin/bash
```

#### Clean Up Docker Resources
```bash
# Remove stopped kind containers
docker container prune --filter "name=kind"

# Remove all kind-related images (be careful!)
docker images | grep kind | awk '{print $3}' | xargs docker rmi
```

### kubectl Commands

#### Check Cluster Status
```bash
# View all nodes
kubectl get nodes

# View nodes with details
kubectl get nodes -o wide

# View node resources
kubectl top nodes
```

#### Check Dgraph Pods
```bash
# View all pods
kubectl get pods

# View pods with node information
kubectl get pods -o wide

# View only Dgraph pods
kubectl get pods -l component=alpha
kubectl get pods -l component=zero

# View pod details
kubectl describe pod <pod-name>
```

#### Check Storage
```bash
# View PersistentVolumes
kubectl get pv

# View PersistentVolumeClaims
kubectl get pvc

# View StorageClass
kubectl get storageclass
```

#### Access Dgraph
```bash
# Port-forward to Alpha HTTP endpoint
kubectl port-forward svc/<release-name>-dgraph-alpha-public 8080:8080

# Port-forward to Alpha gRPC endpoint
kubectl port-forward svc/<release-name>-dgraph-alpha-public 9080:9080

# Port-forward to Ratel UI (if enabled)
kubectl port-forward svc/<release-name>-dgraph-ratel 8000:8000
```

#### View Logs
```bash
# View pod logs
kubectl logs <pod-name>

# Follow logs
kubectl logs -f <pod-name>

# View logs from previous container (if pod restarted)
kubectl logs <pod-name> --previous
```

#### Execute Commands in Pods
```bash
# Access pod shell
kubectl exec -it <pod-name> -- /bin/sh

# Run a command
kubectl exec <pod-name> -- ls -la /dgraph
```

### Helm Commands

#### Check Helm Releases
```bash
# List all releases
helm list

# List releases in specific namespace
helm list -n <namespace>

# View release details
helm status <release-name>
```

#### Upgrade Dgraph
```bash
# Upgrade with new values
helm upgrade <release-name> dgraph/dgraph -f my-values.yaml

# Upgrade with specific namespace
helm upgrade <release-name> dgraph/dgraph -n <namespace> -f my-values.yaml
```

#### Uninstall Dgraph
```bash
# Uninstall release
helm uninstall <release-name>

# Uninstall from specific namespace
helm uninstall <release-name> -n <namespace>
```

## Data Directory Mapping

| Alpha Pod | Host Path (Mac) | Container Path (kind node) | PV Path | PVC Name |
|-----------|----------------|---------------------------|---------|----------|
| alpha-0 | `$HOME/dgraph-data/alpha-0` | `/dgraph-data/alpha-0` | `/dgraph-data/alpha-0` | `datadir-<release>-dgraph-alpha-0` |
| alpha-1 | `$HOME/dgraph-data/alpha-1` | `/dgraph-data/alpha-1` | `/dgraph-data/alpha-1` | `datadir-<release>-dgraph-alpha-1` |
| alpha-2 | `$HOME/dgraph-data/alpha-2` | `/dgraph-data/alpha-2` | `/dgraph-data/alpha-2` | `datadir-<release>-dgraph-alpha-2` |

**Important Notes:**
- All worker nodes share the same mount point (`/dgraph-data`), but each PV uses a unique subdirectory
- Data persists even if you stop/start the kind cluster
- To completely remove data, delete the host directories: `rm -rf ~/dgraph-data/alpha-*`
- The `p` folders contain BadgerDB files that represent your graph data
- **Use absolute paths** for `hostPath` in PVs (shell shortcuts like `~` do not work in YAML)

## Troubleshooting

### Pods Not Starting

If pods are stuck in `Pending` or `CrashLoopBackOff`:

```bash
# Check pod logs
kubectl logs <pod-name>

# Check pod events
kubectl describe pod <pod-name>

# Check node resources
kubectl top nodes
```

### Storage Issues

If data isn't appearing in your host directory:

```bash
# Verify PV's hostPath is correct
kubectl get pv <pv-name> -o jsonpath='{.spec.hostPath.path}'

# Check PVC to PV binding
kubectl get pvc,pv

# Verify pod volume mounts
kubectl describe pod <pod-name> | grep -A 10 "Mounts"

# Test writing to the mount path
kubectl exec -it <pod-name> -- touch /dgraph/test-file
ls -la ~/dgraph-data/alpha-0/test-file
```

### Cluster Not Starting

If the kind cluster won't start:

```bash
# Check Docker is running
docker ps

# Check for port conflicts
docker ps | grep kind

# Delete and recreate
kind delete cluster
./setup.sh
```

## Clean Up

### Uninstall Dgraph
```bash
helm uninstall <release-name>
```

### Delete PersistentVolumes
```bash
kubectl delete pv <pv-name-0> <pv-name-1> <pv-name-2>
```

### Delete kind Cluster
```bash
kind delete cluster
```

### Remove Data Directories
```bash
rm -rf ~/dgraph-data/alpha-*
```

## Additional Resources

- [kind Documentation](https://kind.sigs.k8s.io/)
- [Dgraph Helm Chart](https://github.com/dgraph-io/charts)
- [Dgraph Documentation](https://dgraph.io/docs/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

