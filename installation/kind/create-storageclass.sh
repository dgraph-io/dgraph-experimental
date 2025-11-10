#!/bin/bash
set -e

echo "Creating local-storage StorageClass..."

cat > local-storage-class.yaml << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF

kubectl apply -f local-storage-class.yaml

echo "✓ StorageClass created"
echo ""
echo "Details:"
kubectl get storageclass local-storage -o yaml

echo ""
echo "Key settings:"
echo "  • provisioner: kubernetes.io/no-provisioner (manual PV management)"
echo "  • volumeBindingMode: WaitForFirstConsumer (PV bound when pod scheduled)"
echo "  • reclaimPolicy: Retain (PV not deleted when PVC is deleted)"
