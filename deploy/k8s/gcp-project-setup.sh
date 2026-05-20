#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./gcp-project-setup.sh <command> [options]

Commands:
  create       Create GCP project and enable required APIs
  list-billing List available billing accounts
  delete       Delete GCP project (USE WITH CAUTION)

Required for 'create':
  -p, --project        GCP project ID (must be globally unique, 6-30 chars, lowercase + hyphens)

Options:
  -b, --billing        Billing account ID (required for GKE; use 'list-billing' to find yours)
  -o, --org            Organization ID (optional; project created under org if provided)
  -f, --folder         Folder ID (optional; project created under folder if provided)
      --name           Project display name (default: same as project ID)
      --skip-apis      Skip enabling APIs
  -h, --help           Show help

Examples:
  # List your billing accounts first
  ./gcp-project-setup.sh list-billing

  # Create project with billing (required for GKE)
  ./gcp-project-setup.sh create -p my-dgraph-bench -b 012345-ABCDEF-678901

  # Create project under an organization
  ./gcp-project-setup.sh create -p my-dgraph-bench -b 012345-ABCDEF-678901 -o 123456789

  # Delete project
  ./gcp-project-setup.sh delete -p my-dgraph-bench
USAGE
}

# Defaults
PROJECT=""
BILLING_ACCOUNT=""
ORG_ID=""
FOLDER_ID=""
PROJECT_NAME=""
SKIP_APIS=false
COMMAND=""

log() { echo "$@" >&2; }

die() { log "ERROR: $*"; exit 1; }

check_gcloud() {
  if ! command -v gcloud &>/dev/null; then
    die "gcloud CLI not found. Install: https://cloud.google.com/sdk/docs/install"
  fi

  # Check if authenticated
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    die "Not authenticated. Run: gcloud auth login"
  fi
}

validate_project_id() {
  local pid="$1"
  if [[ ! "$pid" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
    die "Invalid project ID '$pid'. Must be 6-30 lowercase letters, digits, or hyphens. Must start with a letter and end with letter/digit."
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
  create|delete|list-billing) ;;
  -h|--help) usage; exit 0;;
  *) die "Unknown command: $COMMAND";;
esac

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT="${2:?missing value for $1}"; shift 2;;
    -b|--billing) BILLING_ACCOUNT="${2:?missing value for $1}"; shift 2;;
    -o|--org) ORG_ID="${2:?missing value for $1}"; shift 2;;
    -f|--folder) FOLDER_ID="${2:?missing value for $1}"; shift 2;;
    --name) PROJECT_NAME="${2:?missing value for $1}"; shift 2;;
    --skip-apis) SKIP_APIS=true; shift;;
    -h|--help) usage; exit 0;;
    *)
      log "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

list_billing() {
  check_gcloud
  log "Available billing accounts:"
  log ""
  gcloud billing accounts list --format="table(name.basename(), displayName, open)"
  log ""
  log "Use the ACCOUNT_ID (first column) with: -b <ACCOUNT_ID>"
}

create_project() {
  check_gcloud

  if [[ -z "$PROJECT" ]]; then
    die "Missing required flag: --project"
  fi

  validate_project_id "$PROJECT"

  [[ -z "$PROJECT_NAME" ]] && PROJECT_NAME="$PROJECT"

  log "=== GCP Project Setup ==="
  log "Project ID:   $PROJECT"
  log "Display name: $PROJECT_NAME"
  [[ -n "$BILLING_ACCOUNT" ]] && log "Billing:      $BILLING_ACCOUNT"
  [[ -n "$ORG_ID" ]] && log "Organization: $ORG_ID"
  [[ -n "$FOLDER_ID" ]] && log "Folder:       $FOLDER_ID"
  log ""

  # Check if project already exists
  if gcloud projects describe "$PROJECT" &>/dev/null; then
    log "Project '$PROJECT' already exists."
  else
    log "Creating project '$PROJECT'..."

    CREATE_ARGS=(--name "$PROJECT_NAME")
    [[ -n "$ORG_ID" ]] && CREATE_ARGS+=(--organization "$ORG_ID")
    [[ -n "$FOLDER_ID" ]] && CREATE_ARGS+=(--folder "$FOLDER_ID")

    gcloud projects create "$PROJECT" "${CREATE_ARGS[@]}"
    log "Project created."
  fi

  # Link billing account
  if [[ -n "$BILLING_ACCOUNT" ]]; then
    log "Linking billing account '$BILLING_ACCOUNT'..."
    gcloud billing projects link "$PROJECT" --billing-account="$BILLING_ACCOUNT"
    log "Billing linked."
  else
    log ""
    log "WARNING: No billing account specified."
    log "GKE requires billing. Link one with:"
    log "  gcloud billing projects link $PROJECT --billing-account=<ACCOUNT_ID>"
    log ""
    log "Run './gcp-project-setup.sh list-billing' to see available accounts."
  fi

  # Enable APIs
  if $SKIP_APIS; then
    log "Skipping API enablement (--skip-apis)."
  else
    log ""
    log "Enabling required APIs (this may take a minute)..."

    APIS=(
      "container.googleapis.com"      # Kubernetes Engine API
      "compute.googleapis.com"        # Compute Engine API
      "iam.googleapis.com"            # IAM API
      "cloudresourcemanager.googleapis.com"  # Resource Manager API
    )

    for api in "${APIS[@]}"; do
      log "  Enabling $api..."
      gcloud services enable "$api" --project="$PROJECT"
    done

    log "APIs enabled."
  fi

  log ""
  log "=== Setup Complete ==="
  log ""
  log "Next steps:"
  log "  1. Provision GKE cluster:"
  log "     ./gke-provision.sh create -p $PROJECT -c sharded"
  log ""
  log "  2. Or set as default project:"
  log "     gcloud config set project $PROJECT"
}

delete_project() {
  check_gcloud

  if [[ -z "$PROJECT" ]]; then
    die "Missing required flag: --project"
  fi

  if ! gcloud projects describe "$PROJECT" &>/dev/null; then
    log "Project '$PROJECT' does not exist."
    return
  fi

  log "=== GCP Project Deletion ==="
  log "Project: $PROJECT"
  log ""
  log "WARNING: This will delete the project and ALL resources within it."
  log "The project will be recoverable for 30 days, then permanently deleted."
  log ""

  read -r -p "Type the project ID to confirm deletion: " confirm
  if [[ "$confirm" != "$PROJECT" ]]; then
    log "Confirmation failed. Aborted."
    exit 1
  fi

  log "Deleting project '$PROJECT'..."
  gcloud projects delete "$PROJECT" --quiet
  log "Project scheduled for deletion."
}

case "$COMMAND" in
  create) create_project;;
  delete) delete_project;;
  list-billing) list_billing;;
esac
