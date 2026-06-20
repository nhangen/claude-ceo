#!/usr/bin/env bash
# Print current-sprint issues as a JSON array, or [] on any failure. Never crashes.
set -uo pipefail

emit_empty() { echo "[]"; exit 0; }

[ -n "${ZENHUB_TOKEN:-}" ] || emit_empty
[ -n "${ZENHUB_WORKSPACE_ID:-}" ] || emit_empty
command -v curl >/dev/null 2>&1 || emit_empty
command -v jq >/dev/null 2>&1 || emit_empty

read -r -d '' QUERY <<'GQL' || true
query($ws: ID!) {
  workspace(id: $ws) {
    sprints(filters: {state: {eq: OPEN}}, first: 1) {
      nodes { state issues(first: 100) { nodes {
        number title repository { ownerName name }
      } } }
    }
  }
}
GQL

payload=$(jq -n --arg q "$QUERY" --arg ws "$ZENHUB_WORKSPACE_ID" \
  '{query:$q, variables:{ws:$ws}}' 2>/dev/null) || emit_empty

resp=$(curl -sS -X POST "https://api.zenhub.com/public/graphql" \
  -H "Authorization: Bearer $ZENHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>/dev/null) || emit_empty

echo "$resp" | jq -e '.data.workspace.sprints.nodes[0].issues.nodes' >/dev/null 2>&1 || emit_empty

echo "$resp" | jq '[.data.workspace.sprints.nodes[0].issues.nodes[]
  | {number, repo: (.repository.ownerName + "/" + .repository.name), title}]' 2>/dev/null || emit_empty
