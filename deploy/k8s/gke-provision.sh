#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  ./gke-provision.sh <command> [options]

Commands:
  create       Create GKE cluster and deploy Dgraph
  teardown     Delete GKE cluster and associated resources

Required for 'create':
  -p, --project        GCP project ID
  -c, --config         sharded|nonsharded (Dgraph config)

Options:
  -z, --zone           GCP zone (default: us-central1-a)
  -C, --cluster        GKE cluster name (default: dgraph-cluster)
  -m, --machine-type   Node machine type (default: e2-standard-4)
  -N, --num-nodes      Number of nodes (default: 3)
  -n, --namespace      Kubernetes namespace (default: dgraph)
  -r, --release        Helm release name (default: dgraph)
      --disk-size      Boot disk size in GB (default: 100)
      --image-repository  Override Dgraph image repository (e.g. dgraph/dgraph)
      --image-tag         Override Dgraph image tag (e.g. v24.0.5)
      --reset          Delete PVCs before (re)deploying Dgraph
      --lb-source-range CIDR to restrict LB traffic (e.g. your IP/32)
      --emit-env       Print export lines for DGRAPH_* vars
      --shell          Shell syntax for --emit-env: bash|fish (default: bash)
      --skip-deploy    Only create GKE cluster, skip Dgraph deployment
      --delete-disks   (teardown) Also delete orphaned persistent disks
  -h, --help           Show help

Examples:
  # Create cluster and deploy sharded Dgraph
  ./gke-provision.sh create -p my-gcp-project -c sharded

  # Create with custom machine type and node count
  ./gke-provision.sh create -p my-gcp-project -c sharded -m e2-standard-8 -N 5

  # Restrict LoadBalancer to your IP
  ./gke-provision.sh create -p my-gcp-project -c sharded --lb-source-range "$(curl -s ifconfig.me)/32"

  # Teardown cluster
  ./gke-provision.sh teardown -p my-gcp-project

  # Teardown and delete any orphaned disks
  ./gke-provision.sh teardown -p my-gcp-project --delete-disks

  # Export env vars into your current shell:
  eval "$(./gke-provision.sh create -p my-gcp-project -c sharded --emit-env)"
USAGE
}

# Defaults
PROJECT=""
ZONE="us-central1-a"
CLUSTER_NAME="dgraph-cluster"
MACHINE_TYPE="e2-standard-4"
NUM_NODES="3"
DISK_SIZE="100"
NS="dgraph"
REL="dgraph"
CFG=""
RESET=false
EMIT_ENV=false
LB_SOURCE_RANGE=""
SKIP_DEPLOY=false
DELETE_DISKS=false
IMAGE_REPOSITORY=""
IMAGE_TAG=""
SHELL_SYNTAX=""
COMMAND=""

log() { echo "$@" >&2; }

die() { log "ERROR: $*"; exit 1; }

check_gcloud() {
  if ! command -v gcloud &>/dev/null; then
    die "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
  fi
}

check_prerequisites() {
  check_gcloud
  if ! command -v kubectl &>/dev/null; then
    die "kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"
  fi
  if ! command -v helm &>/dev/null; then
    die "helm not found. Install: https://helm.sh/docs/intro/install/"
  fi
}

# Parse command
if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

COMMAND="$1"
shift

case "$COMMAND" in
  create|teardown) ;;
  -h|--help) usage; exit 0;;
  *) die "Unknown command: $COMMAND";;
esac

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT="${2:?missing value for $1}"; shift 2;;
    -z|--zone) ZONE="${2:?missing value for $1}"; shift 2;;
    -C|--cluster) CLUSTER_NAME="${2:?missing value for $1}"; shift 2;;
    -m|--machine-type) MACHINE_TYPE="${2:?missing value for $1}"; shift 2;;
    -N|--num-nodes) NUM_NODES="${2:?missing value for $1}"; shift 2;;
    --disk-size) DISK_SIZE="${2:?missing value for $1}"; shift 2;;
    -c|--config) CFG="${2:?missing value for $1}"; shift 2;;
    -n|--namespace) NS="${2:?missing value for $1}"; shift 2;;
    -r|--release) REL="${2:?missing value for $1}"; shift 2;;
    --reset) RESET=true; shift;;
    --lb-source-range) LB_SOURCE_RANGE="${2:?missing value for $1}"; shift 2;;
    --image-repository) IMAGE_REPOSITORY="${2:?missing value for $1}"; shift 2;;
    --image-tag) IMAGE_TAG="${2:?missing value for $1}"; shift 2;;
    --shell) SHELL_SYNTAX="${2:?missing value for $1}"; shift 2;;
    --emit-env) EMIT_ENV=true; shift;;
    --skip-deploy) SKIP_DEPLOY=true; shift;;
    --delete-disks) DELETE_DISKS=true; shift;;
    -h|--help) usage; exit 0;;
    *)
      log "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

# Validate
if [[ -z "$PROJECT" ]]; then
  die "Missing required flag: --project"
fi

create_cluster() {
  check_prerequisites

  if [[ -z "$CFG" && "$SKIP_DEPLOY" == "false" ]]; then
    die "Missing required flag: --config (sharded|nonsharded)"
  fi

  log "=== GKE Cluster Provisioning ==="
  log "Project:      $PROJECT"
  log "Zone:         $ZONE"
  log "Cluster:      $CLUSTER_NAME"
  log "Machine type: $MACHINE_TYPE"
  log "Nodes:        $NUM_NODES"
  log "Disk size:    ${DISK_SIZE}GB"
  log ""

  # Check if cluster already exists
  if gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT" &>/dev/null; then
    log "Cluster '$CLUSTER_NAME' already exists. Getting credentials..."
  else
    log "Creating GKE cluster '$CLUSTER_NAME'..."
    gcloud container clusters create "$CLUSTER_NAME" \
      --project "$PROJECT" \
      --zone "$ZONE" \
      --machine-type "$MACHINE_TYPE" \
      --num-nodes "$NUM_NODES" \
      --disk-size "${DISK_SIZE}GB" \
      --enable-ip-alias \
      --no-enable-basic-auth \
      --metadata disable-legacy-endpoints=true \
      --scopes "https://www.googleapis.com/auth/cloud-platform"

    log "Cluster created successfully."
  fi

  # Get credentials
  log "Fetching kubectl credentials..."
  gcloud container clusters get-credentials "$CLUSTER_NAME" \
    --zone "$ZONE" \
    --project "$PROJECT"

  log "kubectl context set to cluster '$CLUSTER_NAME'"
  kubectl cluster-info

  if $SKIP_DEPLOY; then
    log ""
    log "Skipping Dgraph deployment (--skip-deploy)."
    log "Run local-provision.sh manually to deploy:"
    log "  ./local-provision.sh -c <sharded|nonsharded> -e gke"
    return
  fi

  # Deploy Dgraph using local-provision.sh
  log ""
  log "=== Deploying Dgraph ==="

  CONFIG_ARGS=(-c "$CFG" -e gke -n "$NS" -r "$REL")
  $RESET && CONFIG_ARGS+=(--reset)
  [[ -n "$LB_SOURCE_RANGE" ]] && CONFIG_ARGS+=(--lb-source-range "$LB_SOURCE_RANGE")
  [[ -n "$IMAGE_REPOSITORY" ]] && CONFIG_ARGS+=(--image-repository "$IMAGE_REPOSITORY")
  [[ -n "$IMAGE_TAG" ]] && CONFIG_ARGS+=(--image-tag "$IMAGE_TAG")
  [[ -n "$SHELL_SYNTAX" ]] && CONFIG_ARGS+=(--shell "$SHELL_SYNTAX")
  $EMIT_ENV && CONFIG_ARGS+=(--emit-env)

  "$SCRIPT_DIR/local-provision.sh" "${CONFIG_ARGS[@]}"
}

delete_orphaned_disks() {
  log "Searching for orphaned disks in zone '$ZONE'..."

  # Find disks that were created by GKE PVCs (they have goog-gke-volume prefix or pvc- in name)
  DISKS=$(gcloud compute disks list \
    --project="$PROJECT" \
    --filter="zone:$ZONE AND (name~'^gke-' OR name~'^pvc-')" \
    --format="value(name)" 2>/dev/null || true)

  if [[ -z "$DISKS" ]]; then
    log "No orphaned disks found."
    return
  fi

  log "Found disks:"
  echo "$DISKS" | while read -r disk; do
    log "  - $disk"
  done

  read -r -p "Delete these disks? [y/N] " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY])
      echo "$DISKS" | while read -r disk; do
        log "Deleting disk '$disk'..."
        gcloud compute disks delete "$disk" \
          --project="$PROJECT" \
          --zone="$ZONE" \
          --quiet || log "  Failed to delete $disk (may already be deleted)"
      done
      log "Disk cleanup complete."
      ;;
    *)
      log "Skipped disk deletion."
      ;;
  esac
}

teardown_cluster() {
  check_gcloud

  log "=== GKE Cluster Teardown ==="
  log "Project:      $PROJECT"
  log "Zone:         $ZONE"
  log "Cluster:      $CLUSTER_NAME"
  log "Delete disks: $DELETE_DISKS"
  log ""

  if ! gcloud container clusters describe "$CLUSTER_NAME" --zone "$ZONE" --project "$PROJECT" &>/dev/null; then
    log "Cluster '$CLUSTER_NAME' does not exist. Nothing to delete."
    return
  fi

  read -r -p "Delete cluster '$CLUSTER_NAME'? This cannot be undone. [y/N] " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY])
      log "Deleting cluster '$CLUSTER_NAME'..."
      gcloud container clusters delete "$CLUSTER_NAME" \
        --zone "$ZONE" \
        --project "$PROJECT" \
        --quiet

      log "Cluster deleted."

      # Clean up kubectl context
      CONTEXT="gke_${PROJECT}_${ZONE}_${CLUSTER_NAME}"
      kubectl config delete-context "$CONTEXT" &>/dev/null || true
      kubectl config delete-cluster "$CONTEXT" &>/dev/null || true

      log "kubectl context cleaned up."

      # Delete orphaned disks if requested
      if $DELETE_DISKS; then
        log ""
        delete_orphaned_disks
      fi
      ;;
    *)
      log "Aborted."
      ;;
  esac
}

case "$COMMAND" in
  create) create_cluster;;
  teardown) teardown_cluster;;
esac
