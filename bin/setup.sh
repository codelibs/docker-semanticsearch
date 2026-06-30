#!/bin/bash
set -euo pipefail

# Run from the repo root regardless of the caller's CWD (script lives in bin/).
cd "$(dirname "$0")/.."

# Read only the keys this script needs from .env WITHOUT sourcing it (docker
# compose parses .env declaratively; sourcing would execute values and break on
# spaces/special chars in unrelated keys like FESS_ADMIN_PASSWORD).
env_get() {
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
THEME_NAME="${THEME_NAME:-$(env_get THEME_NAME)}"
FESS_THEMES_REPO="${FESS_THEMES_REPO:-$(env_get FESS_THEMES_REPO)}"
FESS_THEMES_REF="${FESS_THEMES_REF:-$(env_get FESS_THEMES_REF)}"
FESS_THEMES_DIR="${FESS_THEMES_DIR:-$(env_get FESS_THEMES_DIR)}"
DOMAIN="${DOMAIN:-$(env_get DOMAIN)}"

# Host-side setup for docker-semanticsearch:
#   - create the bind-mount data directories
#   - seed the live system.properties from the tracked template (first run only)
#   - sync the static UI theme from fess-themes
#
# The ML embedding model and the neural ingest pipeline are set up automatically by
# the init-semantic container during `docker compose up`; this script does NOT talk
# to OpenSearch. Re-running it is safe.

THEME_NAME="${THEME_NAME:-semanticlens}"
THEME_DEST="./data/fess/usr/share/fess/app/themes/${THEME_NAME}"

# Seed the per-domain https-portal vhost template for a custom DOMAIN so the
# production bind-mount resolves to a real file (else Docker creates a directory there).
CONF_DIR=./data/https-portal/conf
DEFAULT_ERB="${CONF_DIR}/semantic.codelibs.org.ssl.conf.erb"
if [ -n "${DOMAIN:-}" ] && [ "${DOMAIN}" != "semantic.codelibs.org" ]; then
  mkdir -p "${CONF_DIR}"
  if [ ! -f "${CONF_DIR}/${DOMAIN}.ssl.conf.erb" ] && [ -f "${DEFAULT_ERB}" ]; then
    cp "${DEFAULT_ERB}" "${CONF_DIR}/${DOMAIN}.ssl.conf.erb"
    echo "Seeded ${CONF_DIR}/${DOMAIN}.ssl.conf.erb from the default template."
  fi
fi

# A previous run chowns ./data to the container UIDs (1001/1000). Reclaim it for
# the host user so this re-run can modify/replace files (theme sync, plugin cleanup).
if [ "$(uname -s)" = "Linux" ] && [ -d ./data ]; then
  sudo chown -R "$(id -u)" ./data
fi

echo "Creating directories..."
mkdir -p ./data/https-portal/ssl_certs
mkdir -p ./data/fess/opt/fess
mkdir -p ./data/fess/var/lib/fess
mkdir -p ./data/fess/var/log/fess
mkdir -p ./data/fess/usr/share/fess/app/WEB-INF/plugin
# Remove any previously installed semantic-search plugin jar so a SEMANTIC_PLUGIN_VERSION
# change doesn't leave two versions in the persisted plugin dir (Fess would load
# duplicate components). The image reinstalls the pinned version from FESS_PLUGINS
# on the next `docker compose up`.
rm -f ./data/fess/usr/share/fess/app/WEB-INF/plugin/fess-webapp-semantic-search-*.jar
mkdir -p "${THEME_DEST}"
mkdir -p ./data/opensearch/usr/share/opensearch/data
mkdir -p ./data/opensearch/usr/share/opensearch/config/dictionary
mkdir -p ./data/semantic

# Seed the live system.properties from the tracked template on first run only.
# The live file is git-ignored so Fess can rewrite it (Admin > General) without
# causing git-pull conflicts; an existing file is preserved. To reset to defaults,
# delete it and re-run this script.
SYSTEM_PROPERTIES=./data/fess/opt/fess/system.properties
if [ ! -f "${SYSTEM_PROPERTIES}" ]; then
  echo "Creating ${SYSTEM_PROPERTIES} from template (theme.default=${THEME_NAME})..."
  cp "${SYSTEM_PROPERTIES}.template" "${SYSTEM_PROPERTIES}"
  # Point the default theme at the selected THEME_NAME.
  sed -i.bak "s|^theme\.default=.*|theme.default=${THEME_NAME}|" "${SYSTEM_PROPERTIES}"
  rm -f "${SYSTEM_PROPERTIES}.bak"
fi
if [ -f "${SYSTEM_PROPERTIES}" ]; then
  current="$(grep -E '^theme\.default=' "${SYSTEM_PROPERTIES}" | head -n1 | cut -d= -f2- || true)"
  if [ -n "${current}" ] && [ "${current}" != "${THEME_NAME}" ]; then
    echo "WARNING: live theme.default='${current}' but THEME_NAME='${THEME_NAME}'. Fess will keep using '${current}'."
    echo "         To switch: set theme.default=${THEME_NAME} in ${SYSTEM_PROPERTIES} (or Admin > General), or delete that file and re-run."
  fi
fi

echo "Syncing '${THEME_NAME}' theme from fess-themes..."
# Source resolution:
#   FESS_THEMES_DIR -> copy from a local fess-themes checkout (e.g. ../fess-workspace/repos/fess-themes)
#   otherwise       -> shallow clone FESS_THEMES_REPO @ FESS_THEMES_REF (default branch: main)
FESS_THEMES_REPO="${FESS_THEMES_REPO:-https://github.com/codelibs/fess-themes.git}"
FESS_THEMES_REF="${FESS_THEMES_REF:-main}"

if [ -n "${FESS_THEMES_DIR:-}" ]; then
  src="${FESS_THEMES_DIR}/themes/${THEME_NAME}"
  if [ ! -f "${src}/theme.yml" ]; then
    echo "ERROR: ${src}/theme.yml not found (check FESS_THEMES_DIR / THEME_NAME)." >&2
    exit 1
  fi
  staging="$(mktemp -d)"
  trap 'rm -rf "${staging}"' EXIT
else
  tmpdir="$(mktemp -d)"
  staging="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}" "${staging}"' EXIT
  git clone --depth 1 --branch "${FESS_THEMES_REF}" "${FESS_THEMES_REPO}" "${tmpdir}/fess-themes"
  src="${tmpdir}/fess-themes/themes/${THEME_NAME}"
  if [ ! -f "${src}/theme.yml" ]; then
    echo "ERROR: ${src}/theme.yml not found in ${FESS_THEMES_REPO}@${FESS_THEMES_REF}." >&2
    exit 1
  fi
fi
cp -R "${src}/." "${staging}/"
rm -rf "${THEME_DEST}" && mkdir -p "${THEME_DEST}" && cp -R "${staging}/." "${THEME_DEST}/"
echo "Theme synced to ${THEME_DEST}"

if [ "$(uname -s)" = "Linux" ]; then
  echo "Changing ownership for bind-mount directories..."
  sudo chown -R root ./data/https-portal/ssl_certs
  sudo chown -R 1001 ./data/fess/opt/fess
  sudo chown -R 1001 ./data/fess/var/lib/fess
  sudo chown -R 1001 ./data/fess/var/log/fess
  sudo chown -R 1001 ./data/fess/usr/share/fess/app/WEB-INF/plugin
  sudo chown -R 1001 ./data/fess/usr/share/fess/app/themes
  sudo chown -R 1000 ./data/opensearch/usr/share/opensearch/data
  sudo chown -R 1000 ./data/opensearch/usr/share/opensearch/config/dictionary
  sudo chown -R 1001 ./data/semantic
fi

echo "Setup complete. Next: docker compose up -d"
