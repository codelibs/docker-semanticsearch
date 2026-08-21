#!/bin/sh
# Turns Fess 15.8's content-chunk vector pipeline on, out-of-the-box.
#
# WHY THIS EXISTS
# --------------------------------------------------------------------------------
# In 15.8 chunking and embedding are done by Fess itself, driven by the scheduler
# job "Content Chunk Vector Indexer" (id: content-chunk-vector-indexer). Fess ships
# that job DISABLED and on a once-a-day cron, so a fresh stack would index documents
# but never produce a single vector -- semantic search would stay silently empty
# with no error anywhere. This one-shot companion service:
#
#   1. verifies that the live document index really carries the ANN chunk-vector
#      mapping for the configured dimension/engine (a mismatch means the index was
#      created before the settings were in place and needs a reindex), and
#   2. enables the job with the requested cron and optionally runs it once now.
#
# Idempotent: an already-enabled job with the requested cron is left untouched, so
# restarts are cheap and never clobber operator edits made in the admin UI.
#
# Note on timing: AllJobScheduler re-reads changed jobs every
# fess_config.properties `scheduler.monitor.interval` seconds (default 30), so a
# newly enabled job is not registered with the scheduler the instant it is stored.
# The "run it now" step therefore retries until the job shows up.
set -eu

FESS_URL="${FESS_URL:-http://fess01:8080}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://search01:9200}"
FESS_ADMIN_USER="${FESS_ADMIN_USER:-admin}"
FESS_ADMIN_PASSWORD="${FESS_ADMIN_PASSWORD:-admin}"
JOB_ID="${JOB_ID:-content-chunk-vector-indexer}"
CHUNK_JOB_CRON="${CHUNK_JOB_CRON:-0 * * * *}"
CHUNK_JOB_AUTOSTART="${CHUNK_JOB_AUTOSTART:-true}"
# Seconds to wait after enabling before the first launch attempt. Must exceed
# fess_config.properties `scheduler.monitor.interval` (default 30): launching a job
# the scheduler has not registered yet fails with a JobNotFoundException that Fess
# logs as a full WARN stack trace, so waiting one tick keeps the log clean.
CHUNK_JOB_START_DELAY="${CHUNK_JOB_START_DELAY:-35}"
EXPECTED_DIMENSION="${EXPECTED_DIMENSION:-384}"
EXPECTED_ENGINE="${EXPECTED_ENGINE:-lucene}"
MAX_WAIT="${MAX_WAIT:-300}"

log() { echo "[init-fess-chunk] $*" >&2; }

# Extract the LastaFlute double-submit token from an HTML page on stdin.
extract_token() {
  grep -oE 'TRANSACTION_TOKEN" value="[a-f0-9]+"' | grep -oE '[a-f0-9]{16,}' | head -n1
}

# Extract the optimistic-locking version from the same page. Fess renders -1 when the
# document carries no version yet, so the sign has to be part of the match.
extract_version() {
  grep -oE 'name="versionNo"[^>]*value="-?[0-9]+"' | grep -oE 'value="-?[0-9]+"' | grep -oE -- '-?[0-9]+' | head -n1
}

# ---------------------------------------------------------------------------
# 1. Wait for the document index, then verify the chunk-vector mapping.
# ---------------------------------------------------------------------------
log "Waiting for the Fess document index (fess.search) at ${OPENSEARCH_URL}..."
i=0
until curl -fsS "${OPENSEARCH_URL}/fess.search/_mapping" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "${i}" -ge 120 ] && { log "ERROR: fess.search alias did not appear"; exit 1; }
  sleep 2
done

vector_mapping="$(curl -fsS "${OPENSEARCH_URL}/fess.search/_mapping" \
  | jq -c '[.[].mappings.properties.content_chunk_vector.properties.vector][0] // empty')"
if [ -z "${vector_mapping}" ]; then
  log "ERROR: fess.search has no content_chunk_vector.vector mapping."
  log "       The index predates the content_chunker settings. Re-create it with"
  log "       Admin > System Info > Maintenance > Reindex (with 'Update aliases')."
  exit 1
fi

actual_dim="$(echo "${vector_mapping}" | jq -r '.dimension // empty')"
actual_engine="$(echo "${vector_mapping}" | jq -r '.method.engine // empty')"
knn_setting="$(curl -fsS "${OPENSEARCH_URL}/fess.search/_settings" \
  | jq -r '[.[].settings.index.knn][0] // empty')"

if [ "${actual_dim}" != "${EXPECTED_DIMENSION}" ]; then
  log "ERROR: mapping dimension=${actual_dim:-none} but MODEL_DIMENSION=${EXPECTED_DIMENSION}."
  log "       Reindex after aligning the two, otherwise every embedding is rejected."
  exit 1
fi
if [ "${actual_engine}" != "${EXPECTED_ENGINE}" ]; then
  log "ERROR: mapping engine=${actual_engine:-none} but KNN_ENGINE=${EXPECTED_ENGINE}."
  log "       ANN method settings are baked in at index-creation time; reindex to change them."
  exit 1
fi
if [ "${knn_setting}" != "true" ]; then
  # Without index.knn the searcher silently falls back to an exact (full-scan) scoring
  # mode, which works but does not scale. Surface it rather than hide it.
  log "ERROR: index.knn is not enabled on fess.search (got '${knn_setting:-none}')."
  log "       Reindex so the k-NN index setting is applied."
  exit 1
fi
log "Chunk-vector mapping OK (dimension=${actual_dim}, engine=${actual_engine}, index.knn=true)."

# ---------------------------------------------------------------------------
# 2. Read the current job definition straight from the config index.
#    Using _source (not the HTML form) keeps any operator customisation intact
#    and avoids having to un-escape the Groovy script out of a <textarea>.
# ---------------------------------------------------------------------------
job="$(curl -fsS "${OPENSEARCH_URL}/fess_config.scheduled_job/_doc/${JOB_ID}" \
  | jq -c '._source // empty')"
if [ -z "${job}" ]; then
  log "ERROR: scheduled job '${JOB_ID}' not found. Is this really Fess 15.8+?"
  exit 1
fi

job_available="$(echo "${job}" | jq -r '.available')"
job_cron="$(echo "${job}" | jq -r '.cronExpression // ""')"

if [ "${job_available}" = "true" ] && [ "${job_cron}" = "${CHUNK_JOB_CRON}" ]; then
  log "Job '${JOB_ID}' is already enabled at '${job_cron}'; nothing to do."
  exit 0
fi

log "Enabling job '${JOB_ID}' (available=${job_available} -> true, cron='${job_cron}' -> '${CHUNK_JOB_CRON}')."

COOKIE="$(mktemp)"
PAGE="$(mktemp)"
RESP="$(mktemp)"
trap 'rm -f "${COOKIE}" "${PAGE}" "${RESP}"' EXIT

# ---------------------------------------------------------------------------
# 3. Form login. Credential processing lives in the login() execute method
#    (/login/login); /login/ only renders the form. The default admin password is
#    accepted (Fess returns the change-password page but the session is authenticated).
# ---------------------------------------------------------------------------
login_token="$(curl -fsS -c "${COOKIE}" "${FESS_URL}/login/" | extract_token)"
[ -n "${login_token}" ] || { log "ERROR: could not read the login token"; exit 1; }
curl -fsS -b "${COOKIE}" -c "${COOKIE}" -X POST "${FESS_URL}/login/login" \
  --data-urlencode "username=${FESS_ADMIN_USER}" \
  --data-urlencode "password=${FESS_ADMIN_PASSWORD}" \
  --data-urlencode "lastaflute.action.TRANSACTION_TOKEN=${login_token}" \
  -o /dev/null

# Load the job details page: it both proves the session is authenticated and
# carries the fresh double-submit token plus the current versionNo.
# crudMode 4 = DETAILS (see org.codelibs.fess.app.web.CrudMode).
load_details() {
  curl -fsS -b "${COOKIE}" "${FESS_URL}/admin/scheduler/details/4/${JOB_ID}" -o "${PAGE}"
  grep -q 'name="versionNo"' "${PAGE}" || { log "ERROR: admin login failed (check FESS_ADMIN_PASSWORD)"; return 1; }
}
load_details || exit 1

# Post the whole job form: LastaFlute validates every @Required field, and a
# partial post would blank out the ones left off.
post_job() {
  # $1 = action path, $2 = crudMode, $3 = token, $4 = versionNo, $5 = cron, $6 = available ("on" or "")
  curl -fsS -b "${COOKIE}" -L -X POST "${FESS_URL}$1" \
    --data-urlencode "crudMode=$2" \
    --data-urlencode "id=${JOB_ID}" \
    --data-urlencode "versionNo=$4" \
    --data-urlencode "name=$(echo "${job}" | jq -r '.name')" \
    --data-urlencode "target=$(echo "${job}" | jq -r '.target')" \
    --data-urlencode "cronExpression=$5" \
    --data-urlencode "scriptType=$(echo "${job}" | jq -r '.scriptType')" \
    --data-urlencode "scriptData=$(echo "${job}" | jq -r '.scriptData')" \
    --data-urlencode "sortOrder=$(echo "${job}" | jq -r '.sortOrder')" \
    --data-urlencode "createdBy=$(echo "${job}" | jq -r '.createdBy')" \
    --data-urlencode "createdTime=$(echo "${job}" | jq -r '.createdTime')" \
    $( [ "$(echo "${job}" | jq -r '.jobLogging')" = "true" ] && echo "--data-urlencode jobLogging=on" ) \
    $( [ "$(echo "${job}" | jq -r '.crawler')" = "true" ] && echo "--data-urlencode crawler=on" ) \
    $( [ -n "${6:-}" ] && echo "--data-urlencode available=on" ) \
    --data-urlencode "lastaflute.action.TRANSACTION_TOKEN=$3" \
    -o "${RESP}"
}

# ---------------------------------------------------------------------------
# 4. Enable the job. crudMode 2 = EDIT.
# ---------------------------------------------------------------------------
token="$(extract_token < "${PAGE}")"
version="$(extract_version < "${PAGE}")"
[ -n "${token}" ] && [ -n "${version}" ] || { log "ERROR: could not read the job form token/version"; exit 1; }

post_job "/admin/scheduler/update" 2 "${token}" "${version}" "${CHUNK_JOB_CRON}" on
grep -q "Updated the data" "${RESP}" || { log "ERROR: failed to enable the job; see the admin UI"; exit 1; }
log "Job '${JOB_ID}' enabled at '${CHUNK_JOB_CRON}'."

# ---------------------------------------------------------------------------
# 5. Optionally run it once now so the first crawl gets vectors without waiting
#    for the cron. start() needs the job to be registered with the scheduler,
#    which AllJobScheduler only does on its next monitor tick -- hence the delay
#    before the first attempt, and the retry after it.
# ---------------------------------------------------------------------------
if [ "${CHUNK_JOB_AUTOSTART}" != "true" ]; then
  log "CHUNK_JOB_AUTOSTART=${CHUNK_JOB_AUTOSTART}; not launching the job now."
  exit 0
fi

log "Waiting ${CHUNK_JOB_START_DELAY}s for the scheduler to pick the job up..."
sleep "${CHUNK_JOB_START_DELAY}"
log "Launching '${JOB_ID}' once now..."
waited=0
while :; do
  load_details || exit 1
  token="$(extract_token < "${PAGE}")"
  version="$(extract_version < "${PAGE}")"
  # crudMode 4 = DETAILS, which is what start() verifies.
  if post_job "/admin/scheduler/start" 4 "${token}" "${version}" "${CHUNK_JOB_CRON}" on \
      && grep -q "Started a job" "${RESP}"; then
    log "Job started. Vectors appear as documents are processed (content_chunk_status=done)."
    exit 0
  fi
  waited=$((waited + 10))
  if [ "${waited}" -ge "${MAX_WAIT}" ]; then
    # Non-fatal: the job is enabled and its cron will pick the work up anyway.
    log "WARN: could not launch the job within ${MAX_WAIT}s; it will run on its cron ('${CHUNK_JOB_CRON}')."
    exit 0
  fi
  sleep 10
done
