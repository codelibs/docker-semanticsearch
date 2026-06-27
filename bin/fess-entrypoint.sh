#!/bin/sh
# Fess entrypoint wrapper for docker-semanticsearch.
#
# The fess-webapp-semantic-search plugin reads fess.semantic_search.content.model_id
# via System.getProperty(...), so the OpenSearch ML model id must be passed as a JVM
# system property. The id is generated at model-registration time by the init-semantic
# service, which writes it to /semantic/model_id (a shared volume). This wrapper injects
# it as -D, then launches the stock Fess entrypoint. If the id is not available, Fess
# still starts and serves keyword search; semantic queries activate once it is set.
set -eu

MODEL_ID_FILE="${SEMANTIC_MODEL_ID_FILE:-/semantic/model_id}"
if [ -r "${MODEL_ID_FILE}" ]; then
  model_id="$(cat "${MODEL_ID_FILE}" 2>/dev/null || true)"
  if [ -n "${model_id}" ]; then
    echo "[fess-entrypoint] Injecting semantic model_id=${model_id}"
    export FESS_JAVA_OPTS="${FESS_JAVA_OPTS:-} -Dfess.semantic_search.content.model_id=${model_id}"
  else
    echo "[fess-entrypoint] WARN: ${MODEL_ID_FILE} is empty; semantic queries disabled until set."
  fi
else
  echo "[fess-entrypoint] WARN: ${MODEL_ID_FILE} not found; semantic queries disabled until set."
fi

exec /usr/share/fess/run.sh "$@"
