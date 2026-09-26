#!/usr/bin/env bash
#
# migrate-to-javascript.sh - switch the scripts a Fess 15.8 install stored to
# JavaScript after upgrading it to Fess 15.9 (via the admin API).
#
# Fess 15.9 moved Groovy out of core into the fess-script-groovy plugin and made
# JavaScript the default. An upgrade does not rewrite what is stored in the index,
# so a 15.8 install keeps Groovy on every scheduled job and on every data config
# registered without a script_type (an unset type means Groovy). This deployment
# does not install fess-script-groovy (the WEB-INF/plugin bind mount hides the one
# baked into the image), so after the upgrade those jobs fail - the Default Crawler
# first - and Fess logs "Settings use the script engine groovy, which is not
# registered" at startup.
#
# This script, run once against the upgraded 15.9 server:
#   * scheduled jobs with script type groovy (or none): sets the type to
#     javascript and rewrites the two constructs the 15.8 bundled jobs need
#     changed - the Groovy long literal (1000L -> 1000, Thumbnail Purger) and the
#     org.opensearch package that 15.9 renamed (Index Exporter). The result is
#     exactly the job script Fess 15.9 ships.
#   * data configs with script_type groovy (or none): sets script_type=javascript.
#
# Scripts you customized in Groovy beyond that are switched too; every change is
# printed, so review them (or run with --dry-run first).
#
# Environment:
#   FESS_ENDPOINT      Fess base URL          (default: http://localhost:8080)
#   FESS_ACCESS_TOKEN  admin-api access token (required; Admin > Access Token,
#                      with the permission {role}admin-api)
#
# Requirements: python3.
set -euo pipefail

usage() {
  cat <<'EOF'
migrate-to-javascript.sh - switch 15.8-era Groovy jobs and data configs to JavaScript on Fess 15.9.

Usage:
  FESS_ACCESS_TOKEN=<token> ./bin/migrate-to-javascript.sh [--dry-run]

Options:
  -n, --dry-run   Print what would change; do not update anything
  -h, --help      Show this help and exit
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) dry_run=1; shift;;
    -h|--help)    usage; exit 0;;
    *)            usage >&2; die "unknown argument: $1";;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 not found."
[ -n "${FESS_ACCESS_TOKEN:-}" ] || die "FESS_ACCESS_TOKEN is not set (an admin-api access token: Admin > Access Token)."
: "${FESS_ENDPOINT:=http://localhost:8080}"

DRY_RUN="${dry_run}" FESS_ENDPOINT="${FESS_ENDPOINT}" python3 - <<'PYEOF'
import json, os, re, sys, urllib.error, urllib.request

dry_run = os.environ["DRY_RUN"] == "1"
endpoint = os.environ["FESS_ENDPOINT"].rstrip("/")
token = os.environ["FESS_ACCESS_TOKEN"]

def call(method, path, body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(endpoint + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as res:
            response = json.load(res).get("response", {})
    except urllib.error.HTTPError as e:
        try:
            response = json.load(e).get("response", {})
        except ValueError:
            sys.exit("Error: %s %s failed: HTTP %d" % (method, path, e.code))
    except (urllib.error.URLError, ValueError) as e:
        sys.exit("Error: %s %s failed: %s" % (method, path, e))
    if response.get("status") != 0:
        sys.exit("Error: %s %s failed: %s" % (method, path, response.get("message") or response))
    return response

def list_all(resource):
    settings, page = [], 1
    while True:
        response = call("GET", "/api/admin/%s/settings?size=100&page=%d" % (resource, page))
        batch = response.get("settings", [])
        settings += batch
        if not batch or len(settings) >= int(response.get("total", 0)):
            return response.get("version", ""), settings
        page += 1

def is_groovy(script_type):
    return (script_type or "").strip().lower() in ("", "groovy")

def to_javascript(script):
    # Groovy long literal: JavaScript numbers take no suffix.
    script = re.sub(r"(?<![\w.])(\d+)[lL]\b", r"\1", script)
    # Fess 15.9 dropped the OpenSearch jar for its own fork of the same classes.
    return re.sub(r"\borg\.opensearch\.", "org.codelibs.fesen.opensearch.", script)

version, jobs = list_all("scheduler")
numbers = [int(n) for n in re.findall(r"\d+", version)[:2]]
# Fess 15.8 and earlier have no JavaScript engine: switching there breaks every job.
if len(numbers) < 2 or numbers < [15, 9]:
    sys.exit("Error: run this against Fess 15.9 or later (the server reports '%s'); 15.8 has no JavaScript engine." % version)

changed = 0

for job in jobs:
    if not is_groovy(job.get("script_type")):
        continue
    old = job.get("script_data") or ""
    new = to_javascript(old)
    print("scheduled job %s (%s): %s -> javascript" % (job["id"], job.get("name"), job.get("script_type") or "(unset)"))
    if new != old:
        print("    script: %s\n        -> %s" % (old, new))
    if not dry_run:
        call("PUT", "/api/admin/scheduler/setting", dict(job, script_type="javascript", script_data=new))
    changed += 1

for config in list_all("dataconfig")[1]:
    lines = (config.get("handler_parameter") or "").splitlines()
    is_type = lambda l: "=" in l and l.split("=", 1)[0].strip() == "script_type"
    types = [l.split("=", 1)[1].strip() for l in lines if is_type(l)]
    if types and not is_groovy(types[-1]):
        continue
    params = "\n".join([l for l in lines if not is_type(l)] + ["script_type=javascript"])
    print("data config %s (%s): script_type %s -> javascript" % (config["id"], config.get("name"), types[-1] if types else "(unset)"))
    if not dry_run:
        call("PUT", "/api/admin/dataconfig/setting", dict(config, handler_parameter=params))
    changed += 1

if changed == 0:
    print("Nothing to migrate: no scheduled job or data config uses Groovy.")
elif dry_run:
    print("%d setting(s) would be switched to JavaScript (dry run; nothing changed)." % changed)
else:
    print("Switched %d setting(s) to JavaScript; they apply from the next run." % changed)
    print("Fess checks script engines only at startup, so its groovy warning stays in fess.log until fess01 restarts.")
PYEOF
