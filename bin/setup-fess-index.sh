#!/bin/sh
# Bakes the semantic vector mapping into the Fess document index, out-of-the-box.
#
# WHY THIS EXISTS
# --------------------------------------------------------------------------------
# The fess-webapp-semantic-search plugin injects the knn_vector mapping
# (content_vector / content_chunk), "index.knn": true and the neural
# "default_pipeline" into the document index via rewrite rules registered in
# SemanticSearchHelper#init() (@PostConstruct). However, Fess core
# (SearchEngineClient#open(), also @PostConstruct) CREATES the document index
# earlier in the DI boot order than the plugin registers those rules, and Fess
# applies index rewrite rules ONLY at index-creation time. So the index that Fess
# auto-creates on first boot has NO vector mapping, and hybrid (BM25 + vector)
# search cannot work until the index is re-created while the plugin is active.
#
# The supported way to re-create the document index with the plugin's mapping is
# Admin > Maintenance > Reindex, which runs Fess's own createIndex + addMapping
# (so the rewrite rules apply) and swaps the fess.search / fess.update aliases to
# the new, vector-enabled index. This one-shot companion service performs that
# reindex automatically so a plain `docker compose up` yields a working semantic
# index with no manual step.
#
# Idempotent: if the live document index already exposes the vector field it exits
# immediately, so restarts are cheap and never destroy already-crawled data.
set -eu

FESS_URL="${FESS_URL:-http://fess01:8080}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://search01:9200}"
FESS_ADMIN_USER="${FESS_ADMIN_USER:-admin}"
FESS_ADMIN_PASSWORD="${FESS_ADMIN_PASSWORD:-admin}"
VECTOR_FIELD="${VECTOR_FIELD:-content_vector}"
NUM_SHARDS="${NUM_SHARDS:-5}"
AUTO_EXPAND_REPLICAS="${AUTO_EXPAND_REPLICAS:-0-1}"
MAX_WAIT="${MAX_WAIT:-300}"

log() { echo "[init-fess-index] $*" >&2; }

# Extract the LastaFlute double-submit token from an HTML form on stdin.
extract_token() {
  grep -oE 'TRANSACTION_TOKEN" value="[a-f0-9]+"' | grep -oE '[a-f0-9]{16,}' | head -n1
}

# True when the fess.search mapping already contains the vector field.
doc_has_vector() {
  curl -fsS "${OPENSEARCH_URL}/fess.search/_mapping" 2>/dev/null | grep -q "\"${VECTOR_FIELD}\""
}

# 1. Wait until Fess has created the document index (alias resolvable).
log "Waiting for the Fess document index (fess.search) at ${OPENSEARCH_URL}..."
i=0
until curl -fsS "${OPENSEARCH_URL}/fess.search/_mapping" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "${i}" -ge 120 ] && { log "ERROR: fess.search alias did not appear"; exit 1; }
  sleep 2
done

# 2. Skip if the mapping already has the vector field (idempotent).
if doc_has_vector; then
  log "Document index already has '${VECTOR_FIELD}'; nothing to do."
  exit 0
fi

log "Vector field '${VECTOR_FIELD}' is missing; triggering a Fess reindex to bake it in."

COOKIE="$(mktemp)"
PAGE="$(mktemp)"
trap 'rm -f "${COOKIE}" "${PAGE}"' EXIT

# 3. Form login. Credential processing lives in the login() execute method
#    (/login/login); /login/ only renders the form. The default admin password is
#    accepted (Fess returns the change-password page but the session is authenticated).
login_token="$(curl -fsS -c "${COOKIE}" "${FESS_URL}/login/" | extract_token)"
[ -n "${login_token}" ] || { log "ERROR: could not read the login token"; exit 1; }
curl -fsS -b "${COOKIE}" -c "${COOKIE}" -X POST "${FESS_URL}/login/login" \
  --data-urlencode "username=${FESS_ADMIN_USER}" \
  --data-urlencode "password=${FESS_ADMIN_PASSWORD}" \
  --data-urlencode "lastaflute.action.TRANSACTION_TOKEN=${login_token}" \
  -o /dev/null

# 4. Load the maintenance page (verifies the session) and grab its token.
curl -fsS -b "${COOKIE}" "${FESS_URL}/admin/maintenance/" -o "${PAGE}"
grep -q "Maintenance" "${PAGE}" || { log "ERROR: admin login failed (check FESS_ADMIN_PASSWORD)"; exit 1; }
maint_token="$(extract_token < "${PAGE}")"
[ -n "${maint_token}" ] || { log "ERROR: could not read the maintenance token"; exit 1; }

# 5. Trigger the document-index reindex with alias replacement.
curl -fsS -b "${COOKIE}" -X POST "${FESS_URL}/admin/maintenance/" \
  --data-urlencode "reindexOnly=Start" \
  --data-urlencode "replaceAliases=on" \
  --data-urlencode "numberOfShardsForDoc=${NUM_SHARDS}" \
  --data-urlencode "autoExpandReplicasForDoc=${AUTO_EXPAND_REPLICAS}" \
  --data-urlencode "lastaflute.action.TRANSACTION_TOKEN=${maint_token}" \
  -o /dev/null

# 6. Wait until the new (vector-enabled) index is behind the alias.
log "Reindex requested; waiting for the vector mapping to appear..."
waited=0
until doc_has_vector; do
  waited=$((waited + 3))
  [ "${waited}" -ge "${MAX_WAIT}" ] && { log "ERROR: vector mapping did not appear within ${MAX_WAIT}s"; exit 1; }
  sleep 3
done
log "Document index now has '${VECTOR_FIELD}'. Semantic indexing is ready."
