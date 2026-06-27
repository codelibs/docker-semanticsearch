#!/bin/sh
# Idempotent OpenSearch ML model + neural ingest pipeline setup for Fess semantic
# search. Runs in the init-semantic container (needs curl + jq). Writes the deployed
# model id to ${MODEL_ID_FILE} for the Fess entrypoint wrapper to inject as a JVM -D.
#
# Re-running is safe: an existing model group / deployed model / pipeline is reused
# rather than recreated, so restarts are fast and never register duplicate models.
set -eu

OPENSEARCH_URL="${OPENSEARCH_URL:-http://search01:9200}"
MODEL_NAME="${MODEL_NAME:-huggingface/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2}"
MODEL_VERSION="${MODEL_VERSION:-1.0.1}"
MODEL_FORMAT="${MODEL_FORMAT:-TORCH_SCRIPT}"
MODEL_DIMENSION="${MODEL_DIMENSION:-384}"
PIPELINE_NAME="${PIPELINE_NAME:-neural_pipeline}"
CHUNK_TOKEN_LIMIT="${CHUNK_TOKEN_LIMIT:-100}"
CHUNK_OVERLAP_RATE="${CHUNK_OVERLAP_RATE:-0.1}"
MODEL_ID_FILE="${MODEL_ID_FILE:-/semantic/model_id}"
MAX_WAIT="${MAX_WAIT:-900}"

# Log to stderr so messages survive command substitution and stay visible in
# `docker compose logs init-semantic` (stdout is captured by callers like wait_task).
log() { echo "[setup-semantic] $*" >&2; }

# os METHOD PATH [BODY] -> echoes response body
os() {
  if [ -n "${3:-}" ]; then
    curl -fsS -X "$1" -H 'Content-Type: application/json' "${OPENSEARCH_URL}$2" -d "$3"
  else
    curl -fsS -X "$1" "${OPENSEARCH_URL}$2"
  fi
}

# wait_task TASK_ID [JQ_FIELD] -> waits for COMPLETED, optionally echoes a field
wait_task() {
  _waited=0
  while :; do
    # `|| true` so a transient non-2xx (the cluster is busy downloading/deploying the
    # model in this window) does not abort the script under `set -e`; we just retry.
    _resp="$(os GET "/_plugins/_ml/tasks/$1" || true)"
    _state="$(echo "${_resp}" | jq -r '.state // empty')"
    case "${_state}" in
      COMPLETED) [ -n "${2:-}" ] && echo "${_resp}" | jq -r ".$2 // empty"; return 0 ;;
      FAILED|COMPLETED_WITH_ERROR|CANCELLED)
        log "ERROR: task $1 ${_state}: $(echo "${_resp}" | jq -rc '.error // empty')"; return 1 ;;
    esac
    _waited=$((_waited + 3))
    [ "${_waited}" -ge "${MAX_WAIT}" ] && { log "ERROR: task $1 timed out after ${MAX_WAIT}s"; return 1; }
    sleep 3
  done
}

log "Waiting for OpenSearch at ${OPENSEARCH_URL}..."
i=0
until curl -fsS "${OPENSEARCH_URL}/_cluster/health" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "${i}" -ge 150 ] && { log "ERROR: OpenSearch is not reachable"; exit 1; }
  sleep 2
done

# Allow models to run on non-dedicated ML nodes too (defensive; node already has ml role).
os PUT /_cluster/settings '{"persistent":{"plugins.ml_commons.only_run_on_ml_node":false}}' >/dev/null || true

# Model group: reuse by exact name, else register.
group_id="$(os POST /_plugins/_ml/model_groups/_search \
  "{\"size\":20,\"query\":{\"match\":{\"name\":\"${MODEL_NAME}\"}}}" \
  | jq -r --arg n "${MODEL_NAME}" '[.hits.hits[] | select(._source.name==$n)][0]._id // empty')"
if [ -z "${group_id}" ]; then
  log "Registering model group..."
  group_id="$(os POST /_plugins/_ml/model_groups/_register \
    "{\"name\":\"${MODEL_NAME}\",\"description\":\"Embedding model for Fess semantic search.\"}" \
    | jq -r '.model_group_id // empty')"
fi
[ -n "${group_id}" ] || { log "ERROR: could not determine model_group_id"; exit 1; }
log "model_group_id=${group_id}"

# Model: reuse an existing registered model in the group, else register a new one.
model_id="$(os POST /_plugins/_ml/models/_search \
  "{\"size\":20,\"query\":{\"bool\":{\"must\":[{\"match\":{\"name\":\"${MODEL_NAME}\"}},{\"term\":{\"model_group_id\":\"${group_id}\"}}]}}}" \
  | jq -r --arg n "${MODEL_NAME}" '[.hits.hits[] | select(._source.name==$n and ._source.model_state!=null)][0]._id // empty')"
if [ -z "${model_id}" ]; then
  log "Registering model ${MODEL_NAME} v${MODEL_VERSION} (OpenSearch downloads it; may take several minutes)..."
  task_id="$(os POST /_plugins/_ml/models/_register \
    "{\"name\":\"${MODEL_NAME}\",\"version\":\"${MODEL_VERSION}\",\"model_format\":\"${MODEL_FORMAT}\",\"model_group_id\":\"${group_id}\"}" \
    | jq -r '.task_id // empty')"
  [ -n "${task_id}" ] || { log "ERROR: model registration did not return a task_id"; exit 1; }
  model_id="$(wait_task "${task_id}" model_id)"
fi
[ -n "${model_id}" ] || { log "ERROR: could not determine model_id"; exit 1; }
log "model_id=${model_id}"

# Deploy if not already DEPLOYED.
state="$(os GET "/_plugins/_ml/models/${model_id}" | jq -r '.model_state // empty')"
if [ "${state}" != "DEPLOYED" ]; then
  log "Deploying model (state=${state:-unknown})..."
  dtask="$(os POST "/_plugins/_ml/models/${model_id}/_deploy" | jq -r '.task_id // empty')"
  [ -n "${dtask}" ] && wait_task "${dtask}" >/dev/null || true
  state="$(os GET "/_plugins/_ml/models/${model_id}" | jq -r '.model_state // empty')"
fi
[ "${state}" = "DEPLOYED" ] || { log "ERROR: model is not DEPLOYED (state=${state:-unknown})"; exit 1; }

# Validate the embedding dimension matches the configured index mapping dimension.
actual_dim="$(os GET "/_plugins/_ml/models/${model_id}" | jq -r '.model_config.embedding_dimension // empty')"
if [ -n "${actual_dim}" ] && [ "${actual_dim}" != "${MODEL_DIMENSION}" ]; then
  log "ERROR: model embedding_dimension=${actual_dim} != MODEL_DIMENSION=${MODEL_DIMENSION}. Update MODEL_DIMENSION to match."
  exit 1
fi

# Create/replace the neural ingest pipeline (chunk -> embed).
log "Creating ingest pipeline '${PIPELINE_NAME}'..."
os PUT "/_ingest/pipeline/${PIPELINE_NAME}" "{
  \"description\": \"Neural search pipeline for Fess semantic search\",
  \"processors\": [
    { \"text_chunking\": {
        \"algorithm\": { \"fixed_token_length\": { \"token_limit\": ${CHUNK_TOKEN_LIMIT}, \"overlap_rate\": ${CHUNK_OVERLAP_RATE}, \"tokenizer\": \"standard\" } },
        \"field_map\": { \"content\": \"content_chunk\" } } },
    { \"text_embedding\": {
        \"model_id\": \"${model_id}\",
        \"field_map\": { \"content_chunk\": \"content_vector\" } } }
  ]
}" >/dev/null

# Hand off the model id to the Fess entrypoint wrapper.
mkdir -p "$(dirname "${MODEL_ID_FILE}")"
printf '%s' "${model_id}" > "${MODEL_ID_FILE}"
log "Wrote model_id to ${MODEL_ID_FILE}. Semantic setup complete."
