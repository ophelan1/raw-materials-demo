# Ijzerhaven Raw Materials — AppSignal Kubernetes demo

A B2B ordering system for raw materials (steel coil, copper cathode, cement…)
running on a 3-node Kubernetes cluster (kind, on Colima), standing in for a
self-hosted bare-metal cluster.

```
 traffic (simulated buyers, 1 request every ~10 s)
    │
    ▼
 orders-web ×3  (Ruby / Sinatra / Puma)  ──SQL──▶  postgres
    │  POST /charges  (W3C traceparent)
    ▼
 payments-api ×3 (Ruby / Sinatra)  ──SQL──▶  postgres
    │  mTLS (client cert from secret `acquirer-mtls`)
    ▼
 acquiring bank (simulated)
```

Pods are spread one-per-node across `ijzerhaven-control-plane`,
`ijzerhaven-worker` and `ijzerhaven-worker2`.

## Setup

1. `cp .env.example .env` and fill in:
   - `APPSIGNAL_PUSH_API_KEY`
   - `APPSIGNAL_COLLECTOR_ENDPOINT` — App settings → Hosted Collector → Collector URL
     (distributed tracing only works through the hosted collector)
   - `APPSIGNAL_K8S_API_KEY` — the app-specific push API key, for Cluster Metrics
   - `APPSIGNAL_FRONTEND_API_KEY` — App settings → Front-end error monitoring key,
     baked into the storefront bundle (it is public by design)
2. `scripts/up.sh` (rerunnable; it rebuilds images and restarts pods)
3. Storefront (React, AppSignal for Browser): http://localhost:8080. Place an
   order during a failure window to see the browser error and its back-end trace
   together. Browser data lands in the `browser` namespace.

Tear down with `scripts/down.sh`, then `colima stop`.

## The incident

Every 10 minutes (wall clock: :00, :10, :20 … for 2 minutes) a "certificate
rotation" makes payments-api load `client-2026q4.crt`, which was never added to
the `acquirer-mtls` secret. Every **card** charge fails (`AcquirerTLSError`) →
orders-web marks the order failed (`PaymentFailedError`, HTTP 502). **Invoice**
orders (~25%) don't touch the acquirer and keep succeeding — a partial outage,
not a total one. ~1.5% of card payments are ordinary bank declines (402, not
errors) all the time, as background noise.

Traffic is kept low for a 50K-requests/month AppSignal plan: ~6 requests a
minute, and each order counts twice (orders-web + payments-api), so about
10 AppSignal requests a minute, ~14K a day. Change `REQUESTS_PER_SECOND` on
the traffic deployment in `k8s/app.yaml` to adjust.

Tune with `FAILURE_INTERVAL_MINUTES` / `FAILURE_DURATION_SECONDS` on the
payments-api deployment in `k8s/app.yaml`.

## Demo script

**1. Infrastructure (Cluster Metrics).** Open the app → Cluster Metrics. Show the
3 nodes, then drill into pods: orders-web / payments-api / postgres, CPU and
memory per pod, network per node. Point out: one agent Deployment, read-only
RBAC, one secret — fits their self-hosted setup with no cloud dependency.

**2. APM — a healthy request.** Performance → `POST /api/orders` in
orders-web. Open a sample trace: request → `sql.sequel` (material lookup, stock
check, INSERT order) → `request.net_http POST http://payments-api:4000` →
*crosses into payments-api* (`POST /charges`, `load_certificate.acquirer`,
`request.acquirer`, INSERT payment_attempt) → back to orders-web → UPDATE order
+ stock. Tags show `customer`, `order_reference`, `pod`, `node`.

**3. The spike.** Errors → issue list shows `PaymentFailedError` (orders-web)
and `AcquirerTLSError` (payments-api) spiking at the top of each 10-minute mark.
Custom metric `orders` tagged `status=failed` jumps; `payment_method=invoice`
stays green.

**4. Troubleshoot.**
- Open `PaymentFailedError` → *"Order ORD-… failed: payments-api returned 502
  (acquirer_tls_error: mTLS handshake … client certificate
  /etc/payments/tls/client-2026q4.crt not found …)"*.
- Open its trace → the failing span is in **payments-api**, not orders-web.
- Jump to Logs, filter on the `payments` group / `order_reference`:
  `Acquirer mTLS handshake aborted: client certificate not found`
  with `cert_path`, `mounted_files=client.crt,client.key`,
  `k8s_secret=acquirer-mtls` and the `hint` → root cause: the rotation expects a
  cert that the Kubernetes secret doesn't contain.
- Back on Cluster Metrics: the pods are healthy (no CPU/memory/restarts story)
  — it's a config problem, which is why you need APM + logs alongside infra.

## Useful commands

```
kubectl -n ijzerhaven get pods -o wide
kubectl -n ijzerhaven logs -f deploy/traffic
kubectl -n ijzerhaven logs -l app=payments-api -f | grep -i certificate
kubectl -n ijzerhaven exec deploy/payments-api -- ls /etc/payments/tls
```

Metrics emitted: `orders` (counter; `status`, `payment_method`),
`order_value_eur` (distribution), `payment_attempts` (counter; `result`,
`payment_method`) — good material for a custom "Orders" dashboard.

## MQTT (RabbitMQ)

RabbitMQ runs the MQTT plugin (`k8s/app.yaml`, ConfigMap `rabbitmq-config`).

- `sensors`: 12 silo level sensors (Rotterdam and Delft), one MQTT client each,
  publishing `ijzerhaven/<site>/silo/<sku>/level` at QoS 1 every ~15 s, with a
  retained `status` and a last will of `offline`. About once every 25 minutes
  per sensor one drops off without disconnecting and returns 20–60 s later.
- `telemetry`: persistent-session consumer of levels, status and
  `ijzerhaven/dispatch/#`; writes `silo_levels` to Postgres. It **pauses for
  90 s at :05, :20, :35 and :50**, so the backlog and end-to-end latency
  graphs climb and then drain.
- `orders-web`: every paid order publishes a dispatch message, visible as a
  `publish.mqtt` span in the order trace.
- `mqtt-metrics`: broker metrics. MQTT message rates come from the Prometheus
  endpoint (`:15692`), because the management API stopped reporting them in
  RabbitMQ 3.12. Backlog per session comes from the management API.

Dashboard: "MQTT: silo telemetry". Good demo moments: watch "Subscriber
backlog" and "End-to-end latency" at :05/:20/:35/:50, and point out that the
pause is a consumer problem, not a sensor problem, because every sensor's
"seconds since last reading" climbs at once.
