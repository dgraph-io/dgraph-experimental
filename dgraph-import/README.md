# Dgraph Import

## Overview

The `dgraph import` command, introduced in **v25.0.0** is designed to unify and simplify bulk and live data loading into Dgraph. Previously, users had to choose between `dgraph bulk` and `dgraph live`. With `dgraph import`, you now have a single command for both workflows, eliminating manual steps and reducing operational complexity.

> **Note:**  
> The original intent was to support both bulk and live loading, but **live loader mode is not yet supported**. Only bulk/snapshot import is available.

## How Data Is Imported

When you run `dgraph import`, the tool first runs the bulk loader using your provided RDF/JSON and schema files. This generates the snapshot data in the form of `p` directories (BadgerDB files) for each group.  
After the bulk loader completes, `dgraph import` connects to the Alpha endpoint, puts the cluster into drain mode, and **streams the contents of the generated `p` directories directly to the running cluster using gRPC bidirectional streaming**. Once the import is complete, the cluster exits drain mode and resumes normal operation.

If you already have a snapshot directory (from a previous bulk load), you can use the `--snapshot-dir` flag to skip the bulk loading phase and directly stream the snapshot data to the cluster.

This means you no longer need to stop Alpha nodes or manually manage files—`dgraph import` handles everything automatically.

## Command Syntax

```
dgraph import [flags]
```

### Essential Flags

| Flag | Description |
|------|-------------|
| `--files, -f` | Path to RDF/JSON data files (e.g., `data.rdf`, `data.json`) |
| `--schema, -s` | Path to DQL schema file |
| `--graphql_schema, -g` | Path to GraphQL schema file |
| `--format` | File format: `rdf` or `json` |
| `--snapshot-dir, -p` | Path to existing snapshot output directory for direct import |
| `--drop-all` | Drop all existing cluster data before import (enables bulk loader) |
| `--drop-all-confirm` | Confirmation flag for `--drop-all` operation |
| `--conn-str, -c` | Dgraph connection string (e.g., `dgraph://localhost:9080`) |

## Quick Start

### Bulk Import with Data and Schema

```
dgraph import --files data.rdf --schema schema.dql \
              --drop-all --drop-all-confirm \
              --conn-str dgraph://localhost:9080
```

Loads data from `data.rdf`, drops existing cluster data, runs the bulk loader to generate a snapshot, and streams it to the cluster.

### Import from Existing Snapshot

```
dgraph import --snapshot-dir ./out --conn-str dgraph://localhost:9080
```

Directly streams snapshot data (output of a previous bulk load) into the cluster, without running the bulk loader again.

## Snapshot Directory Structure

The bulk loader generates an `out` directory with per-group subdirectories:

```
out/
├── 0/
│   └── p/          # BadgerDB files for group 0
├── 1/
│   └── p/          # BadgerDB files for group 1
└── N/
    └── p/          # BadgerDB files for group N
```

When using `--snapshot-dir`, provide the `out` directory path. The import tool automatically locates `p` directories within each group folder.

**Important:** Do not specify the `p` directory directly.

## How It Works

1. **Drop-All Mode**: With `--drop-all` and `--drop-all-confirm`, the bulk loader generates a snapshot from provided data and schema files.
2. **Snapshot Streaming**: The snapshot (contents of `p` directories) is streamed to the cluster via gRPC, copying all data directly into the running cluster.
3. **Consistency**: The cluster enters drain mode during import. On error, all data is dropped for safety.

## Import Examples

**RDF with DQL schema:**
```
dgraph import --files data.rdf --schema schema.dql \
              --drop-all --drop-all-confirm \
              --conn-str dgraph://localhost:9080
```

**JSON with GraphQL schema:**
```
dgraph import --files data.json --schema schema.dql \
              --graphql-schema schema.graphql --format json \
              --drop-all --drop-all-confirm \
              --conn-str dgraph://localhost:9080
```

**Existing snapshot:**
```
dgraph import --snapshot-dir ./out --conn-str dgraph://localhost:9080
```

## Benchmark Import

For testing with large datasets, Dgraph provides sample 1-million-record datasets.

**Download benchmark files:**

```
wget https://github.com/dgraph-io/dgraph-benchmarks/blob/main/data/1million.rdf.gz?raw=true
wget https://github.com/dgraph-io/dgraph-benchmarks/blob/main/data/1million.schema?raw=true
```

**Run benchmark import:**

```
dgraph import --files 1million.rdf.gz --schema 1million.schema \
              --drop-all --drop-all-confirm \
              --conn-str dgraph://localhost:9080
```

## Important Notes

- When `--drop-all` and `--drop-all-confirm` flags are set, **all existing data in the cluster will be dropped** before the import begins.
- Both `--drop-all` and `--drop-all-confirm` flags are required for bulk loading; the command aborts without them.
- Live loader mode is not supported; only snapshot/bulk import is available.
- Ensure sufficient disk space for snapshot generation.
- Connection string must use gRPC format: `dgraph://localhost:9080`.