# Power PoV: AppSignal as an AI solution for Kubernetes Ruby stacks

Every row of the "Success Criteria" tab, mapped to where it's shown in AppSignal
(app **Ijzerhaven Orders / production**, org *Kubernetes Demo*) and how it's
built in this repo. "MCP" means asking Claude (or any MCP client) with the
AppSignal MCP server connected; the prompts below are the ones to type.

Base URL: `https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a`

## Links

| Name | Link |
|---|---|
| Golden signals: Ruby services | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d6386585066c9b60e11) |
| Performance (actions, drill-down) | [performance](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/performance) |
| Errors | [exceptions](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/exceptions?incident_marker=all) |
| Failing order, traced across services | [trace](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/performance/traces/orders-web%2Fweb/POST%20%2Fapi%2Forders/traces/7a3e550bfe972064f06e1128f4f6e373) |
| Logs (with trace_id/span_id on every line) | [logs](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/logs) |
| SQL: Postgres | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad85cfea37570a87fb60e64) |
| SQL: MySQL | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d64203c662539b60e1b) |
| Redis + Sentinel | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d648871c04710b60e26) |
| HAProxy | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d648871c04710b60e28) |
| Background jobs: Solid Queue | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d6486585066c9b60e13) |
| Kubernetes control plane | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d6579587fd9b4b60e52) |
| Ingress: nginx + Traefik | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d658871c04710b60e2c) |
| Cluster capacity (incl. node loss, OOM) | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad84fc157c32d5366b60e76) |
| SLOs: order availability | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d6579587fd9b4b60e54) |
| Logs: API and job analytics | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d65457b698ad9b60dfd) |
| Usage and billing | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad86d6679587fd9b4b60e56) |
| MQTT: silo telemetry | [dashboard](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/metrics/6ad8625f156f229cd8b60e4f) |
| Alerts (anomaly triggers) | [triggers](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/triggers) |
| Log line actions (log metrics + log alerts) | [actions](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a/logs/actions) |
| Cluster Metrics (built-in Kubernetes view) | [app](https://appsignal.com/kubernetes-demo/sites/6ad846a1f2103d81d1b60e6a), then **Cluster Metrics** in the left nav |

## Requirement by requirement

Status: ✅ shown live · ⚠️ partly / with a caveat · ❌ not offered.

### Application Performance

| Row | Requirement | Status | Where | How it's done |
|---|---|---|---|---|
| 4 | OOTB golden metrics with drill-down | ✅ | Golden signals dashboard; Performance | Latency (mean/p95), traffic, error rate per service from AppSignal's own trace metrics, plus pod saturation. Click through Performance → action → trace → span. |
| 5 | Automatic logs ↔ traces ↔ metrics correlation, no code changes | ✅ | Logs; failing order trace | The AppSignal Ruby gem adds `trace_id` and `span_id` to every log line automatically (see any "Order failed" line). Traces show related logs; Pod/node tags tie traces to Cluster Metrics. |
| 6 | App context ↔ services it depends on | ✅ | Failing order trace (service map) | One trace spans orders-web → Postgres, Redis, MQTT publish → payments-api → Postgres. Every span carries `k8s.pod.name`, `k8s.node.name` and a link to its Deployment YAML on GitHub. |
| 8 | MySQL clusters (PMM alternative) | ✅ / ⚠️ | SQL: MySQL | `datastore-metrics` reads SHOW GLOBAL STATUS and Performance Schema digests (PMM's sources): heaviest query shapes, rows examined per call, buffer pool, row locks, full scans. Demo is a single instance; replication lag is reported when `SHOW REPLICA STATUS` has rows. |
| 9 | PostgreSQL clusters | ✅ | SQL: Postgres | `postgres-metrics`: pg_stat_statements top queries, connections by state, cache hit, bloat, locks, long transactions. |
| 10 | Redis with Sentinel | ✅ | Redis + Sentinel | 2 data nodes + 3 Sentinels. Masters seen, quorum, role per node (failover), replication lag, hit rate, memory, evictions; app-side cache hit/miss. |
| 11 | HAProxy | ✅ | HAProxy | HAProxy's built-in Prometheus endpoint, discovered by annotation through the Prometheus bridge. |
| 12 | Background jobs (Resque → Solid Queue) | ✅ | Background jobs: Solid Queue; Performance → `fulfillment/background` | A Rails worker on Solid Queue. AppSignal's Active Job/Solid Queue integration gives per-job timing, errors and retries, plus built-in queue time metrics. Solid Queue's own tables give "what is running, for how long, what's waiting". Resque is also a native AppSignal integration. |
| 13 | Other DB specs | — | (question) | Covered by the two SQL dashboards plus per-query spans in traces. |

### Kubernetes Management

| Row | Requirement | Status | Where | How it's done |
|---|---|---|---|---|
| 16 | OOTB Kubernetes monitoring | ✅ | Cluster Metrics; Cluster capacity | `appsignal-kubernetes` agent (one Deployment, read-only RBAC) gives node/pod CPU, memory, disk, network. Capacity dashboard adds allocatable vs requested vs used. |
| 17 | Prometheus exporters scraping for custom dashboards/alerts | ✅ | Kubernetes control plane → "Scrape targets up" | `prometheus-bridge` scrapes any pod/service annotated `prometheus.io/scrape: "true"`, plus static control-plane endpoints. Curated rules turn counters into rates and histograms into mean/p95; unknown exporters get a capped passthrough. |
| 19 | API Server | ✅ | Kubernetes control plane | Requests by verb/status, latency p95, inflight, etcd latency. |
| 20 | Scheduler | ✅ | Kubernetes control plane | Pending pods by queue, attempts by result, attempt latency. |
| 21 | Kubelet | ✅ | Kubernetes control plane | Running pods/containers per node, pod start time, PLEG relist, runtime errors. |
| 22 | Etcd | ✅ | Kubernetes control plane | Has leader, leader changes, failed proposals, DB size, WAL fsync / commit p95. |
| 23 | CoreDNS | ✅ | Kubernetes control plane | Responses by rcode, latency, cache. |
| 24 | Cilium | ⚠️ | — | This demo cluster (kind) uses kindnet, not Cilium. The bridge config has ready rules for cilium-agent; annotate its pods and uncomment. |
| 25 | Nginx Ingress Controller | ✅ | Ingress: nginx + Traefik | Requests by status class, latency mean/p95, connections, config reload. |
| 26 | Traefik Ingress Controller | ✅ | Ingress: nginx + Traefik | Requests by service/status, latency, open connections. |
| 27 | Platform alerts routed by namespace / owner team | ✅ | Triggers: "[platform team] …", "[orders team] …" | Triggers scoped with `pod_namespace` tag filters; each points at that team's notifier. |
| 28 | Reproduce dashboards, filter by cluster/namespace | ✅ / ⚠️ | All k8s dashboards | Pod metrics carry `pod_namespace`, `workload`, `node_name`; bridge metrics carry `cluster`. Filters are tag wildcards per graph. |
| 29 | Keess (internal Prometheus exporter) | ✅ (pattern) | — | One annotation on Keess's pods; passthrough until rules are written (template in `k8s/prometheus-bridge.yml`). |
| 30 | Out-of-memory kills | ✅ | Cluster capacity → "Out-of-memory kills…"; trigger "Pod OOM-killed" | `report-renderer` leaks memory and is OOM-killed every 20–40 min. |
| 31 | Capacity analysis: node loss simulator | ✅ | Cluster capacity → "Node loss simulator…", "Survives losing any one node" | For each node: requested % on the remaining nodes, headroom, and pods/CPU to reschedule; one N+1 flag. |
| 32 | SLIs and SLOs | ✅ | SLOs: order availability; trigger "SLO … burning fast" | Availability SLI (5 min, 1 h, SLO window), error budget, burn rate, fast-burn alert. Apdex (Labs) per namespace can be switched on under Performance → Apdex. |
| 33 | Multi-year SLI retention | ⚠️ | — | Depends on AppSignal plan retention; confirm with AppSignal. |

### QA support (log-based investigations)

| Row | Requirement | Status | Where | How it's done |
|---|---|---|---|---|
| 35 | Advanced queries: regex extraction, math, stats | ✅ via MCP | Logs; MCP | AppSignal's query language filters and groups server-side (`log_metrics` group-by). Claude does the regex/math step. See prompts below; both Splunk examples were reproduced live. |
| 36 | Alerts from logs | ✅ | Log line actions → "Acquirer mTLS client certificate missing" | Ingestion-time trigger on a log query. |
| 37 | Dashboards from log stats | ✅ | Logs: API and job analytics | Log line actions turn api_response lines into call counts and latency (from `duration_ms`), "Order failed" lines into counts and € at risk. |
| 38 | Reports from logs | ✅ via MCP | MCP | Ask Claude for the report; schedule it as a recurring task. |

### Pricing transparency

| Row | Requirement | Status | Where | How it's done |
|---|---|---|---|---|
| 41 | Forecast/anomaly monitors on billing metrics | ✅ | Usage and billing; triggers "Billing: …" | Billed volume (`site_throughput`, `log_ingestion`) graphed per service/source; triggers fire on monthly pace, before the invoice. |

### Other features

| Row | Requirement | Status | Where | How it's done |
|---|---|---|---|---|
| 44 | Light lock-in, data portability | ✅ | — | Ruby services report over OpenTelemetry (OTLP via the hosted collector); exporters speak plain Prometheus; everything is readable through MCP/CLI. |
| 45 | Browser / RUM | ✅ | [Browser errors](https://appsignal.com/redirect-to/app?to=browser/errors&app_id=6ad846a1f2103d81d1b60e6a), [Browser performance](https://appsignal.com/redirect-to/app?to=browser/performance&app_id=6ad846a1f2103d81d1b60e6a) | React storefront (`services/storefront`, http://localhost:8080) runs AppSignal for Browser: JS errors per route, page loads and web vitals, tagged with the deployed revision. API calls send `traceparent`, so an order placed in the browser and the orders-web → payments-api spans are one trace. A failed payment (502) shows as a browser error linked to that trace. |
| 46 | Mobile | ❌ | — | No native mobile SDK. |
| 47 | Synthetic / availability | ⚠️ | — | AppSignal uptime monitors (4 regions, per-phase timing, SSL expiry) need a public URL; this demo runs on a laptop. One MCP call creates one. |
| 48 | AI assistance | ✅ | MCP + CLI | AppSignal MCP: query traces, errors, logs, metrics; create dashboards, triggers, log actions, uptime monitors. Every dashboard and alert in this PoV was built through it. |
| 49 | IaC for SaaS configuration | ⚠️ | — | `appsignal-cli` creates dashboards, charts (JSON, including layout) and triggers from scripts/CI. No Terraform provider found. |
| 50 | Operator for SaaS configuration | ❌ | — | No Kubernetes operator for AppSignal config; CLI from a Job/CI is the alternative. |
| 51 | Dashboard versioning | ⚠️ | — | Chart definitions as JSON in git, applied with `appsignal-cli dashboards add-visual / update-visual`. |
| 52 | External data sources without hosting the data | ❌ / ⚠️ | — | AppSignal graphs data sent to it; external sources are pushed (bridge pattern), not queried in place. |

## MCP prompts that reproduce the Splunk tab

1. **QA team, job duration by Job ID**
   > In Ijzerhaven Orders production, find the "Enqueued Dispatch::TruckScheduleJob" and "Performed Dispatch::TruckScheduleJob" log lines for the last 3 hours, extract the Job ID from each with a regex, pair them, and give me a table of time, job ID and duration in seconds and minutes, sorted by time.

   Live result: 954781ca… 4.24 s, f272de36… 8.11 s, 43ee3753… 8.54 s; each Performed line links to its trace.

2. **Mail dashboard, count by status** (analogue: payment outcomes)
   > Count payments log lines in the last 24 hours, grouped by message (authorized, declined, mTLS handshake aborted).

3. **Dev team, endpoint stats with path normalisation**
   > For api_response and api_error log lines in the last hour, normalise the path (replace order references like ORD-xxxx with {reference}, strip query strings), then give me calls, errors (event=api_error or http_status >= 400), error %, avg, p50, p95 and max duration_ms per "METHOD path", sorted by error % then p95.

   Server side, `log_metrics` groups by `path`; Claude applies the regexes and math.

4. **Incident triage**
   > Why are orders failing right now? Start from the newest PaymentFailedError, follow its trace into payments-api and show me the log line that explains it.
