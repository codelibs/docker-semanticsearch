#!/bin/sh
# Fess entrypoint wrapper for docker-semanticsearch.
#
# Fess 15.8 reads content_chunker.* from the system.properties channel, which also
# accepts a -Dfess.system.<key> boot option. The OpenSearch ML Commons model id is
# generated at model-registration time by the init-semantic service, which writes it
# to /semantic/model_id (a shared volume), so it can only be known at container start.
# This wrapper injects it as -Dfess.system.content_chunker.embedding.opensearch.model.id
# and then launches the stock Fess entrypoint.
#
# If the id is not available, Fess still starts and serves keyword search; the id is
# read only once here, so vector indexing and semantic queries activate only after
# fess01 is (re)started with the id present (no live reload).
#
# Note: a value for the same key inside /opt/fess/system.properties would take
# precedence over this -D, so the key is intentionally kept out of that file
# (see data/fess/opt/fess/system.properties.template).
set -eu

MODEL_ID_FILE="${SEMANTIC_MODEL_ID_FILE:-/semantic/model_id}"
if [ -r "${MODEL_ID_FILE}" ]; then
  model_id="$(cat "${MODEL_ID_FILE}" 2>/dev/null || true)"
  if [ -n "${model_id}" ]; then
    echo "[fess-entrypoint] Injecting embedding model_id=${model_id}"
    export FESS_JAVA_OPTS="${FESS_JAVA_OPTS:-} -Dfess.system.content_chunker.embedding.opensearch.model.id=${model_id}"
  else
    echo "[fess-entrypoint] WARN: ${MODEL_ID_FILE} is empty; semantic search disabled until set."
  fi
else
  echo "[fess-entrypoint] WARN: ${MODEL_ID_FILE} not found; semantic search disabled until set."
fi

exec /usr/share/fess/run.sh "$@"
