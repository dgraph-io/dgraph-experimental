#!/bin/bash
set -e

# Configuration
RELEASE_NAME=${1:-hatest}
NAMESPACE=${2:-default}
HOST_DATA_PATH=${3:-~/dgraph-data}
CONTAINER_DATA_PATH="/dgraph-data"

echo "=== Simplified Dgraph Storage Setup ==="
echo ""
echo "Configuration:"
echo "  Release name: $RELEASE_NAME"
echo "  Namespace: $NAMESPACE"
echo "  Host path (Mac): $HOST_DATA_PATH"
echo "  Container path (workers): $CONTAINER_DATA_PATH"
echo ""

if [ -z "$1" ]; then
  echo "💡 TIP: You can specify custom values:"
  echo "   $0 <release-name> [namespace] [host-data-path]"
  echo ""
  read -p "Continue with defaults? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted. Run with: $0 my-release-name default /path/to/data"
    exit 1
  fi
fi

# Step 1: Create local directories
echo "Step 1: Creating local directories..."
mkdir -p ${HOST_DATA_PATH}/alpha-0
mkdir -p ${HOST_DATA_PATH}/alpha-1
mkdir -p ${HOST_DATA_PATH}/alpha-2
echo "✓ Directories created at ${HOST_DATA_PATH}/alpha-{0,1,2}"
echo ""

# Step 2: Confirm cluster recreation
echo "Step 2: Recreating kind cluster..."
echo "⚠️  This will DELETE your existing kind cluster!"
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

kind delete cluster 2>/dev/null || true
echo "✓ Old cluster deleted"

# Step 3: Generate simplified kind config
echo ""
echo "Step 3: Generating kind cluster config..."
cat > kind-cluster-config.yaml << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
  extraMounts:
  - hostPath: ${HOST_DATA_PATH}
    containerPath: ${CONTAINER_DATA_PATH}
- role: worker
  extraMounts:
  - hostPath: ${HOST_DATA_PATH}
    containerPath: ${CONTAINER_DATA_PATH}
- role: worker
  extraMounts:
  - hostPath: ${HOST_DATA_PATH}
    containerPath: ${CONTAINER_DATA_PATH}
EOF

echo "✓ Config generated: kind-cluster-config.yaml"
echo "  All workers mount: ${HOST_DATA_PATH} → ${CONTAINER_DATA_PATH}"

# Step 4: Create cluster
echo ""
echo "Step 4: Creating kind cluster..."
kind create cluster --config kind-cluster-config.yaml

echo "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
echo "✓ Cluster created and ready"
echo ""

# Step 5: Create StorageClass
echo "Step 5: Creating StorageClass..."
cat > local-storage-class.yaml << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF

kubectl apply -f local-storage-class.yaml
echo "✓ StorageClass 'local-storage' created"
echo ""

# Step 6: Generate PVs dynamically
echo "Step 6: Generating PersistentVolumes for release '$RELEASE_NAME'..."
cat > dgraph-alpha-pvs.yaml << EOF
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RELEASE_NAME}-dgraph-alpha-pv-0
  labels:
    alpha-pod-index: "0"
    release: ${RELEASE_NAME}
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  claimRef:
    namespace: ${NAMESPACE}
    name: datadir-${RELEASE_NAME}-dgraph-alpha-0
  hostPath:
    path: ${CONTAINER_DATA_PATH}/alpha-0
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RELEASE_NAME}-dgraph-alpha-pv-1
  labels:
    alpha-pod-index: "1"
    release: ${RELEASE_NAME}
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  claimRef:
    namespace: ${NAMESPACE}
    name: datadir-${RELEASE_NAME}-dgraph-alpha-1
  hostPath:
    path: ${CONTAINER_DATA_PATH}/alpha-1
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RELEASE_NAME}-dgraph-alpha-pv-2
  labels:
    alpha-pod-index: "2"
    release: ${RELEASE_NAME}
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  claimRef:
    namespace: ${NAMESPACE}
    name: datadir-${RELEASE_NAME}-dgraph-alpha-2
  hostPath:
    path: ${CONTAINER_DATA_PATH}/alpha-2
EOF

echo "✓ PV manifest generated: dgraph-alpha-pvs.yaml"
echo ""
echo "PV Mapping:"
echo "  PV pv-0 → ${CONTAINER_DATA_PATH}/alpha-0 → Mac ${HOST_DATA_PATH}/alpha-0"
echo "  PV pv-1 → ${CONTAINER_DATA_PATH}/alpha-1 → Mac ${HOST_DATA_PATH}/alpha-1"
echo "  PV pv-2 → ${CONTAINER_DATA_PATH}/alpha-2 → Mac ${HOST_DATA_PATH}/alpha-2"
echo ""
sleep 1

# Step 6: Apply PVs
echo "Step 6: Creating PersistentVolumes..."
kubectl apply -f dgraph-alpha-pvs.yaml

echo ""
kubectl get pv
echo ""
sleep 2

# Step 7: Install Helm chart
echo "Step 7: Installing Dgraph Helm chart with release name '$RELEASE_NAME'..."

helm repo add dgraph https://charts.dgraph.io 2>/dev/null || true
helm repo update

helm install ${RELEASE_NAME} dgraph/dgraph \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --wait \
  --timeout 10m \
  -f my-values.yaml

echo "✓ Dgraph installed with release name: $RELEASE_NAME"

# Step 8: Wait for pods
echo ""
echo "Step 8: Waiting for all alpha pods to be ready..."
kubectl wait --for=condition=Ready pod -l component=alpha -n ${NAMESPACE} --timeout=300s
echo "✓ All alpha pods are ready"

# Step 9: Verification
echo ""
echo "========================================"
echo "    VERIFICATION RESULTS"
echo "========================================"
echo ""

echo "📊 PVC to PV Binding:"
echo "--------------------"
for i in 0 1 2; do
  pvc="datadir-${RELEASE_NAME}-dgraph-alpha-$i"
  pv=$(kubectl get pvc $pvc -n ${NAMESPACE} -o jsonpath='{.spec.volumeName}' 2>/dev/null || echo "NOT_FOUND")
  expected_pv="${RELEASE_NAME}-dgraph-alpha-pv-$i"
  
  if [ "$pv" = "$expected_pv" ]; then
    echo "✅ PVC $pvc → PV $pv"
  else
    echo "❌ PVC $pvc → PV $pv (Expected $expected_pv)"
  fi
done

echo ""
echo "📍 Pod Distribution Across Nodes:"
echo "---------------------------------"
kubectl get pods -l component=alpha -n ${NAMESPACE} -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,STATUS:.status.phase --no-headers

echo ""
echo "💾 Data Directory Contents:"
echo "--------------------------"
for i in 0 1 2; do
  dir="${HOST_DATA_PATH}/alpha-$i"
  if [ -d "$dir" ]; then
    count=$(ls -A "$dir" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" -gt 0 ]; then
      echo "✅ $dir ($count items)"
      ls -1 "$dir" | head -3 | sed 's/^/    /'
    else
      echo "⚠️  $dir (empty - Dgraph may still be initializing)"
    fi
  else
    echo "❌ $dir (does not exist)"
  fi
done

echo ""
echo "========================================"
echo "    SETUP COMPLETE"
echo "========================================"
echo ""
echo "📝 Summary:"
echo "  • All workers share mount: ${HOST_DATA_PATH} → ${CONTAINER_DATA_PATH}"
echo "  • Each PV uses unique subdirectory (alpha-0, alpha-1, alpha-2)"
echo "  • No node affinity needed - paths are unique!"
echo ""
echo "Quick Commands:"
echo ""
echo "  # Check pods and which node they're on"
echo "  kubectl get pods -l component=alpha -n ${NAMESPACE} -o wide"
echo ""
echo "  # Check PVC bindings"
echo "  kubectl get pvc -n ${NAMESPACE}"
echo ""
echo "  # Check data on Mac"
echo "  ls -la ${HOST_DATA_PATH}/alpha-*/"
echo ""
echo "  # Check data inside pod"
echo "  kubectl exec -it ${RELEASE_NAME}-dgraph-alpha-0 -n ${NAMESPACE} -- ls -la /dgraph"
echo ""
echo "  # View logs"
echo "  kubectl logs ${RELEASE_NAME}-dgraph-alpha-0 -n ${NAMESPACE}"
echo ""
