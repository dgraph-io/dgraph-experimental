#!/bin/bash

# Convert Dgraph JSON schema to text schema format
# Usage: ./convert_schema.sh input.json > schema.dql

# JSON format is returned by `schema{}` query.
# curl -X POST -H "Content-Type: application/dql" \
# localhost:8080/query -d $'schema {}'  > schema.json

# Text format is used by the alter command to update the schema.


if [ $# -eq 0 ]; then
    echo "Usage: $0 <json_file>" >&2
    exit 1
fi

json_file="$1"

if [ ! -f "$json_file" ]; then
    echo "Error: File '$json_file' not found" >&2
    exit 1
fi

# Process predicates (schema)
echo "# Predicates"
jq -r '.data.schema[] | 
    "<" + .predicate + ">: " + .type + " " +
    (if .index then 
        "@index(" + (.tokenizer | join(",")) + ")" 
     else "" end) + " " +
    (if .reverse then "@reverse" else "" end) + " " +
    (if .upsert then "@upsert" else "" end) + " " +
    (if .unique then "@unique" else "" end) + " " +
    (if .list then "[" + .type + "]" else "" end) + " " +
    " ." | 
    gsub("  +"; " ") | 
    gsub(" \\."; ".")' "$json_file"

echo ""

# Process types
jq -r '.data.types[] | 
    "type <" + .name + "> {\n" +
    (.fields | map("\t" + .name) | join("\n")) +
    "\n}"' "$json_file"
