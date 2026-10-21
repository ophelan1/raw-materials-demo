#!/usr/bin/env bash
# Creates (or updates) the 3-node demo cluster and deploys everything.
# Safe to rerun: after editing .env, after changing code, or after a reboot.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && set -a && source .env && set +a
: "${APPSIGNAL_APP_NAME:=Ijzerhaven Orders}"

colima status >/dev/null 2>&1 || colima start --cpu 6 --memory 10 --disk 40

if ! kind get clusters | grep -qx ijzerhaven; then
  kind create cluster --config k8s/kind-cluster.yaml
  # Let the control-plane node run workloads too, like a small bare-metal cluster.
  kubectl taint nodes ijzerhaven-control-plane node-role.kubernetes.io/control-plane:NoSchedule- || true
fi
kubectl config use-context kind-ijzerhaven >/dev/null

echo "==> Building images"
for svc in orders-web payments traffic capacity-metrics; do
  docker build -q -t "ijzerhaven/$svc:1" "services/$svc" >/dev/null
  kind load docker-image --name ijzerhaven "ijzerhaven/$svc:1" >/dev/null
done

kubectl apply -f - <<<'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"ijzerhaven"}}' >/dev/null

echo "==> Secrets"
if ! kubectl -n ijzerhaven get secret acquirer-mtls >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=payments.ijzerhaven.internal" \
    -keyout "$tmp/client.key" -out "$tmp/client.crt" 2>/dev/null
  kubectl -n ijzerhaven create secret generic acquirer-mtls \
    --from-file=client.crt="$tmp/client.crt" --from-file=client.key="$tmp/client.key"
  rm -rf "$tmp"
fi
kubectl -n ijzerhaven create secret generic appsignal-app \
  --from-literal=app-name="$APPSIGNAL_APP_NAME" \
  --from-literal=push-api-key="${APPSIGNAL_PUSH_API_KEY:-}" \
  --from-literal=collector-endpoint="${APPSIGNAL_COLLECTOR_ENDPOINT:-}" \
  --from-literal=revision="$(git rev-parse HEAD 2>/dev/null || echo dev)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "==> Deploying app"
kubectl apply -f k8s/app.yaml >/dev/null
# Apps create their tables on boot, so Postgres must be up before they restart.
kubectl -n ijzerhaven rollout status deployment postgres --timeout=120s >/dev/null
kubectl -n ijzerhaven rollout restart deployment orders-web payments-api traffic capacity-metrics >/dev/null
kubectl -n ijzerhaven rollout status deployment orders-web payments-api --timeout=180s

if [ -n "${APPSIGNAL_K8S_API_KEY:-}" ]; then
  echo "==> Deploying AppSignal Kubernetes agent"
  kubectl apply -f - <<<'{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"appsignal"}}' >/dev/null
  kubectl -n appsignal create secret generic appsignal --from-literal=api-key="$APPSIGNAL_K8S_API_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f k8s/appsignal-kubernetes.yaml >/dev/null
  kubectl -n appsignal rollout restart deployment appsignal-kubernetes >/dev/null
else
  echo "==> Skipping AppSignal Kubernetes agent (APPSIGNAL_K8S_API_KEY not set)"
fi

echo
kubectl get pods -A -o wide | grep -E "NAME|ijzerhaven |appsignal "
echo
echo "Catalogue: http://localhost:8080   Traffic log: kubectl -n ijzerhaven logs -f deploy/traffic"
