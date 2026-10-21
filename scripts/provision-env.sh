#!/usr/bin/env bash
# Fills .env from the AppSignal provisioning API without printing any keys.
# Creates the app and, if the organization has none, a hosted collector, then
# waits for the collector to be provisioned. Safe to rerun: both calls resolve
# existing resources instead of duplicating them.
# Usage: scripts/provision-env.sh '<status URL with ?token=...>'
set -euo pipefail
cd "$(dirname "$0")/.."

STATUS_URL="$1"
BASE="${STATUS_URL%%/api/provision/*}/api/provision/v1"
TOKEN="${STATUS_URL##*token=}"
APP_NAME="Ijzerhaven Orders"
APP_ENV="production"

api() { curl -sSf -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$@"; }
collector_url() {
  python3 -I -c 'import json,sys
cs=[c for c in json.load(sys.stdin)["organization"]["hosted_collectors"] if c.get("status")=="provisioned"]
print(cs[0]["url"] if cs else "")'
}

app=$(api -X POST "$BASE/apps" -d "{\"name\":\"$APP_NAME\",\"environment\":\"$APP_ENV\"}")

status=$(curl -sSf "$STATUS_URL")
if [ "$(python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["organization"]["hosted_collectors"]))' <<<"$status")" = 0 ]; then
  echo "Creating hosted collector"
  api -X POST "$BASE/hosted_collectors" -d '{"description":"Ijzerhaven Orders k8s demo"}' >/dev/null
fi
until [ -n "$(collector_url <<<"$status")" ]; do
  echo "Waiting for hosted collector to be provisioned..."
  sleep 30
  status=$(curl -sSf "$STATUS_URL")
done

STATUS="$status" APP="$app" APP_NAME="$APP_NAME" COLLECTOR="$(collector_url <<<"$status")" python3 -I - <<'EOF'
import json, os
status = json.loads(os.environ["STATUS"])
app = json.loads(os.environ["APP"])
values = {
    "APPSIGNAL_APP_NAME": os.environ["APP_NAME"],
    "APPSIGNAL_PUSH_API_KEY": status["push_api_key"],
    "APPSIGNAL_COLLECTOR_ENDPOINT": os.environ["COLLECTOR"],
    "APPSIGNAL_K8S_API_KEY": app["app"]["push_api_key"],
}
fd = os.open(".env", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    for k, v in values.items():
        f.write(f'{k}="{v}"\n')
print(f"App: {app['app']['name']} / {app['app']['environment']} (created: {app['created']})")
print(f"Collector: {os.environ['COLLECTOR']}")
print("Wrote .env (keys not shown). Next: scripts/up.sh")
EOF
