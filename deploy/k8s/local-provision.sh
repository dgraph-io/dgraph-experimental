#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./local-provision.sh --config sharded|nonsharded --expose local|gke [options]

Required:
  -c, --config         sharded|nonsharded
  -e, --expose         local|gke

Options:
  -n, --namespace      Kubernetes namespace (default: dgraph)
  -r, --release        Helm release name (default: dgraph)
      --image-repository  Override Dgraph image repository (e.g. dgraph/dgraph)
      --image-tag         Override Dgraph image tag (e.g. v24.0.5)
      --reset          Delete PVCs for this release before (re)deploying
      --lb-source-range CIDR to restrict LB traffic (e.g. 1.2.3.4/32) (gke only)
      --emit-env       Print export lines for DGRAPH_* vars (for eval)
      --shell          Shell syntax for --emit-env: bash|fish (default: bash)
  -h, --help           Show help

Examples:
  # Local (NodePort) fresh deploy
  ./local-provision.sh -c sharded -e local --reset

  # Pin a specific Dgraph version
  ./local-provision.sh -c sharded -e local --image-tag v24.0.5

  # Export env vars into your current shell (bash/zsh):
  eval "$(./local-provision.sh -c sharded -e local --emit-env)"

  # Export env vars into your current shell (fish):
  ./local-provision.sh -c sharded -e local --emit-env --shell fish | source

Note:
  For GKE deployments, use ./gke-provision.sh — it creates the cluster,
  sets the kubectl context, and invokes this script with -e gke.
USAGE
}

# Defaults
NS="dgraph"
REL="dgraph"
CFG=""
EXPOSE=""
RESET=false
EMIT_ENV=false
LB_SOURCE_RANGE=""
IMAGE_REPOSITORY=""
IMAGE_TAG=""
SHELL_SYNTAX="bash"

# Logging helper (keep stdout clean if using --emit-env)
log() { echo "$@" >&2; }

# Parse args (supports short + long)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config) CFG="${2:?missing value for $1}"; shift 2;;
    -e|--expose) EXPOSE="${2:?missing value for $1}"; shift 2;;
    -n|--namespace) NS="${2:?missing value for $1}"; shift 2;;
    -r|--release) REL="${2:?missing value for $1}"; shift 2;;
    --reset) RESET=true; shift;;
    --lb-source-range) LB_SOURCE_RANGE="${2:?missing value for $1}"; shift 2;;
    --image-repository) IMAGE_REPOSITORY="${2:?missing value for $1}"; shift 2;;
    --image-tag) IMAGE_TAG="${2:?missing value for $1}"; shift 2;;
    --shell) SHELL_SYNTAX="${2:?missing value for $1}"; shift 2;;
    --emit-env) EMIT_ENV=true; shift;;
    -h|--help) usage; exit 0;;
    *)
      log "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

# Validate required args
if [[ -z "$CFG" || -z "$EXPOSE" ]]; then
  log "Missing required flags."
  usage
  exit 2
fi

case "$CFG" in
  sharded|nonsharded) ;;
  *) log "Invalid --config: $CFG"; exit 2;;
esac

case "$EXPOSE" in
  local|gke) ;;
  *) log "Invalid --expose: $EXPOSE"; exit 2;;
esac

case "$SHELL_SYNTAX" in
  bash|fish) ;;
  *) log "Invalid --shell: $SHELL_SYNTAX (expected bash|fish)"; exit 2;;
esac

VALUES_FILE="values-${CFG}.yaml"
if [[ ! -f "$VALUES_FILE" ]]; then
  log "Values file not found: $VALUES_FILE"
  exit 1
fi

ALPHA_SVC="${REL}-dgraph-alpha"

if $EMIT_ENV; then
  # --emit-env is a pure lookup: the release must already be deployed.
  if ! kubectl -n "$NS" get svc "$ALPHA_SVC" >/dev/null 2>&1; then
    log "ERROR: service '$ALPHA_SVC' not found in namespace '$NS'."
    log "Deploy first with: ./local-provision.sh -c $CFG -e $EXPOSE"
    exit 1
  fi
else
  # Ensure namespace exists
  kubectl create ns "$NS" >/dev/null 2>&1 || true

  # Helm repo
  helm repo add dgraph https://charts.dgraph.io >/dev/null 2>&1 || true
  helm repo update >/dev/null

  # Optional: full teardown of the Helm release + PVCs for a clean slate.
  # This is needed because StatefulSet has immutable fields (e.g. volumeClaimTemplates,
  # selectors), so a plain `helm upgrade` after config changes will fail with
  # "Forbidden: updates to statefulset spec ... are forbidden".
  if $RESET; then
    if helm status "$REL" -n "$NS" >/dev/null 2>&1; then
      log "Reset enabled: uninstalling helm release '$REL' in namespace '$NS'"
      helm uninstall "$REL" -n "$NS" --wait 1>&2 || true
    else
      log "Reset enabled: no existing release '$REL' to uninstall"
    fi

    log "Reset enabled: deleting PVCs for release=$REL in namespace=$NS"
    kubectl -n "$NS" delete pvc -l release="$REL" --ignore-not-found 1>&2 || true
  fi

  # Decide exposure mode for Alpha and Zero services
  SVC_FLAGS=()
  case "$EXPOSE" in
    local)
      SVC_FLAGS+=(--set alpha.service.type=NodePort)
      # Expose Zero as NodePort too so admin (6080) and raft (5080) are reachable
      # from the host. On GKE we leave Zero as ClusterIP — the admin API is sensitive
      # and users can `kubectl port-forward` when needed.
      SVC_FLAGS+=(--set zero.service.type=NodePort)
      ;;
    gke)
      SVC_FLAGS+=(--set alpha.service.type=LoadBalancer)
      if [[ -n "$LB_SOURCE_RANGE" ]]; then
        SVC_FLAGS+=(--set alpha.service.loadBalancerSourceRanges[0]="$LB_SOURCE_RANGE")
      fi
      ;;
  esac

  # Optional image overrides
  [[ -n "$IMAGE_REPOSITORY" ]] && SVC_FLAGS+=(--set image.repository="$IMAGE_REPOSITORY")
  [[ -n "$IMAGE_TAG" ]] && SVC_FLAGS+=(--set image.tag="$IMAGE_TAG")

  log "Deploying: cfg=$CFG expose=$EXPOSE ns=$NS release=$REL${IMAGE_REPOSITORY:+ image=$IMAGE_REPOSITORY}${IMAGE_TAG:+:$IMAGE_TAG}"
  helm upgrade --install "$REL" dgraph/dgraph -n "$NS" -f "$VALUES_FILE" "${SVC_FLAGS[@]}" 1>&2

  kubectl -n "$NS" rollout status "statefulset/${REL}-dgraph-zero" 1>&2
  kubectl -n "$NS" rollout status "statefulset/${REL}-dgraph-alpha" 1>&2
fi

# Determine endpoints and export env vars (but note: exports won't persist unless sourced/eval'd)
HOST=""
HTTP_PORT=""
GRPC_PORT=""
ZERO_HTTP_PORT=""
ZERO_GRPC_PORT=""
ZERO_SVC="${REL}-dgraph-zero"

if [[ "$EXPOSE" == "local" ]]; then
  # NodePort assigned on the Alpha service
  PORT_MAP="$(kubectl -n "$NS" get svc "$ALPHA_SVC" -o jsonpath='{range .spec.ports[*]}{.port}{" "}{.nodePort}{"\n"}{end}')"
  HTTP_PORT="$(echo "$PORT_MAP" | awk '$1==8080{print $2}')"
  GRPC_PORT="$(echo "$PORT_MAP" | awk '$1==9080{print $2}')"
  HOST="localhost"

  if [[ -z "${HTTP_PORT:-}" || -z "${GRPC_PORT:-}" ]]; then
    log "Could not determine NodePorts for $ALPHA_SVC. Got:"
    log "$PORT_MAP"
    exit 1
  fi

  # NodePorts on the Zero service (optional — only present when deployed with -e local)
  ZERO_PORT_MAP="$(kubectl -n "$NS" get svc "$ZERO_SVC" -o jsonpath='{range .spec.ports[*]}{.port}{" "}{.nodePort}{"\n"}{end}' 2>/dev/null || true)"
  ZERO_HTTP_PORT="$(echo "$ZERO_PORT_MAP" | awk '$1==6080{print $2}')"
  ZERO_GRPC_PORT="$(echo "$ZERO_PORT_MAP" | awk '$1==5080{print $2}')"
else
  # Wait for LoadBalancer IP/hostname
  for _ in $(seq 1 120); do
    IP="$(kubectl -n "$NS" get svc "$ALPHA_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    HN="$(kubectl -n "$NS" get svc "$ALPHA_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    HOST="${IP:-$HN}"
    [[ -n "$HOST" ]] && break
    sleep 2
  done

  if [[ -z "$HOST" ]]; then
    log "LoadBalancer external address is still empty for $ALPHA_SVC."
    log "Try: kubectl -n $NS get svc $ALPHA_SVC -w"
    exit 1
  fi

  HTTP_PORT="8080"
  GRPC_PORT="9080"
fi

DGRAPH_ALPHA_HTTP_URL="http://${HOST}:${HTTP_PORT}"
DGRAPH_ALPHA_GRPC_ADDR="${HOST}:${GRPC_PORT}"

DGRAPH_ZERO_HTTP_URL=""
DGRAPH_ZERO_GRPC_ADDR=""
if [[ -n "$ZERO_HTTP_PORT" ]]; then
  DGRAPH_ZERO_HTTP_URL="http://${HOST}:${ZERO_HTTP_PORT}"
fi
if [[ -n "$ZERO_GRPC_PORT" ]]; then
  DGRAPH_ZERO_GRPC_ADDR="${HOST}:${ZERO_GRPC_PORT}"
fi

if $EMIT_ENV; then
  # Print env-setting statements so the user can load them into their shell.
  case "$SHELL_SYNTAX" in
    bash)
      echo "export DGRAPH_ALPHA_HTTP_URL=\"${DGRAPH_ALPHA_HTTP_URL}\""
      echo "export DGRAPH_ALPHA_GRPC_ADDR=\"${DGRAPH_ALPHA_GRPC_ADDR}\""
      [[ -n "$DGRAPH_ZERO_HTTP_URL" ]] && echo "export DGRAPH_ZERO_HTTP_URL=\"${DGRAPH_ZERO_HTTP_URL}\""
      [[ -n "$DGRAPH_ZERO_GRPC_ADDR" ]] && echo "export DGRAPH_ZERO_GRPC_ADDR=\"${DGRAPH_ZERO_GRPC_ADDR}\""
      ;;
    fish)
      echo "set -gx DGRAPH_ALPHA_HTTP_URL \"${DGRAPH_ALPHA_HTTP_URL}\""
      echo "set -gx DGRAPH_ALPHA_GRPC_ADDR \"${DGRAPH_ALPHA_GRPC_ADDR}\""
      [[ -n "$DGRAPH_ZERO_HTTP_URL" ]] && echo "set -gx DGRAPH_ZERO_HTTP_URL \"${DGRAPH_ZERO_HTTP_URL}\""
      [[ -n "$DGRAPH_ZERO_GRPC_ADDR" ]] && echo "set -gx DGRAPH_ZERO_GRPC_ADDR \"${DGRAPH_ZERO_GRPC_ADDR}\""
      ;;
  esac
else
  log "Alpha endpoint:"
  log "  DGRAPH_ALPHA_HTTP_URL=${DGRAPH_ALPHA_HTTP_URL}"
  log "  DGRAPH_ALPHA_GRPC_ADDR=${DGRAPH_ALPHA_GRPC_ADDR}"
  if [[ -n "$DGRAPH_ZERO_HTTP_URL" || -n "$DGRAPH_ZERO_GRPC_ADDR" ]]; then
    log "Zero endpoint:"
    [[ -n "$DGRAPH_ZERO_HTTP_URL" ]] && log "  DGRAPH_ZERO_HTTP_URL=${DGRAPH_ZERO_HTTP_URL}"
    [[ -n "$DGRAPH_ZERO_GRPC_ADDR" ]] && log "  DGRAPH_ZERO_GRPC_ADDR=${DGRAPH_ZERO_GRPC_ADDR}"
  fi
  log ""
  log "Tip: to export into your current shell:"
  log "  bash/zsh: eval \"\$(./local-provision.sh -c $CFG -e $EXPOSE --emit-env)\""
  log "  fish:     ./local-provision.sh -c $CFG -e $EXPOSE --emit-env --shell fish | source"
fi
