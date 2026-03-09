#!/usr/bin/env bash
##
## Generate Prometheus scrape targets from a Dgraph docker-compose file.
##
## Parses Dgraph Alpha and Zero services to extract hostnames and HTTP ports,
## then writes prometheus/targets/dgraph.json.
##
## Requirements: docker (compose v2), jq
##
## Usage:
##   ./generate-targets.sh /path/to/dgraph/docker-compose.yml
##   ./generate-targets.sh /path/to/dgraph/docker-compose.yml my-cluster
##

set -euo pipefail

COMPOSE_FILE="${1:?Usage: $0 <docker-compose.yml> [cluster-name]}"
CLUSTER_NAME="${2:-dgraph}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGETS_FILE="${SCRIPT_DIR}/prometheus/targets/dgraph.json"

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  echo "  brew install jq" >&2
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: File not found: $COMPOSE_FILE" >&2
  exit 1
fi

# Get normalized compose config as JSON
CONFIG=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null)

if [[ -z "$CONFIG" ]]; then
  echo "Error: Failed to parse $COMPOSE_FILE" >&2
  exit 1
fi

# Extract Dgraph services and their --my flag to determine hostnames and ports.
# Dgraph port layout (base + offset):
#   Alpha: internal=7080, http=8080 (internal + 1000)
#   Zero:  internal=5080, http=6080 (internal + 1000)
#
# The --my flag gives us <hostname>:<internal_port>, so http_port = internal_port + 1000

TARGETS=$(echo "$CONFIG" | jq -r --arg cluster "$CLUSTER_NAME" '
  [.services | to_entries[] |
    # Only process services whose command contains "dgraph alpha" or "dgraph zero"
    select(.value.command != null) |
    .key as $svc |
    .value.command as $cmd |

    # Normalize command to a string (may be string or array)
    ($cmd | if type == "array" then join(" ") else tostring end) as $cmdstr |

    # Only Dgraph services
    select($cmdstr | test("dgraph (alpha|zero)")) |

    # Determine component type
    (if ($cmdstr | test("dgraph alpha")) then "alpha" else "zero" end) as $component |

    # Extract --my=host:port
    ($cmdstr | capture("--my=(?<host>[^:\\s]+):(?<port>\\d+)") // null) as $my |

    select($my != null) |

    # Calculate HTTP/metrics port (internal + 1000)
    (($my.port | tonumber) + 1000 | tostring) as $http_port |

    {
      targets: [($my.host + ":" + $http_port)],
      labels: {
        job: ("dgraph-" + $component),
        cluster: $cluster,
        component: $component,
        instance: $svc
      }
    }
  ]
')

if [[ "$TARGETS" == "[]" || -z "$TARGETS" ]]; then
  echo "Error: No Dgraph services found in $COMPOSE_FILE" >&2
  exit 1
fi

# Write targets file
mkdir -p "$(dirname "$TARGETS_FILE")"
echo "$TARGETS" | jq '.' > "$TARGETS_FILE"

echo "Generated $TARGETS_FILE:"
echo "$TARGETS" | jq -r '.[] | "  \(.labels.instance): \(.targets[0]) (\(.labels.component))"'
echo ""
echo "Prometheus will auto-reload targets within 30s."

# Also print the network name for convenience
PROJECT_DIR="$(cd "$(dirname "$COMPOSE_FILE")" && basename "$(pwd)")"
echo ""
echo "To connect monitoring to this cluster's network:"
echo "  DGRAPH_NETWORK=${PROJECT_DIR}_default \\"
echo "    docker compose -f docker-compose.yml -f docker-compose.network.yml up -d"
