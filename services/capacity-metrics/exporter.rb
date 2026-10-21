# Capacity metrics exporter: reports what a self-hosted cluster has, what's
# been promised to workloads (requests/limits) and what's actually used, so
# AppSignal dashboards can answer "how close are we to full?".
#
# The appsignal-kubernetes agent already sends raw usage (cpu_usage_nano_cores,
# memory_working_set_bytes, fs_*, network_*). This adds capacity, commitments
# and the ratios between them, using the same node_name / pod_namespace /
# pod_name tags so the two line up on a dashboard.
require "json"
require "logger"
require "net/http"
require "openssl"
require "appsignal"

Appsignal.start
LOG = Logger.new($stdout)
INTERVAL = Integer(ENV.fetch("INTERVAL_SECONDS", "30"))

module Kube
  SA = "/var/run/secrets/kubernetes.io/serviceaccount"
  URI_BASE = URI("https://#{ENV.fetch("KUBERNETES_SERVICE_HOST")}:#{ENV.fetch("KUBERNETES_SERVICE_PORT")}")

  def self.get(path, raw: false)
    http = Net::HTTP.new(URI_BASE.host, URI_BASE.port)
    http.use_ssl = true
    http.ca_file = "#{SA}/ca.crt"
    http.read_timeout = 15
    request = Net::HTTP::Get.new(path, "Authorization" => "Bearer #{File.read("#{SA}/token")}")
    response = http.request(request)
    raise "GET #{path}: #{response.code}" unless response.code == "200"
    raw ? response.body : JSON.parse(response.body)
  end
end

# Kubernetes quantities ("250m", "512Mi", "2") to cores / bytes.
def cpu(q)
  return 0.0 if q.nil?
  q.end_with?("m") ? q.to_f / 1000 : (q.end_with?("n") ? q.to_f / 1e9 : q.to_f)
end

UNITS = { "Ki" => 2**10, "Mi" => 2**20, "Gi" => 2**30, "Ti" => 2**40, "k" => 1e3, "M" => 1e6, "G" => 1e9, "T" => 1e12 }.freeze
def bytes(q)
  return 0.0 if q.nil?
  unit = UNITS.keys.find { |u| q.end_with?(u) }
  unit ? q.delete_suffix(unit).to_f * UNITS[unit] : q.to_f
end

def pct(part, whole)
  whole.to_f.positive? ? (part.to_f / whole * 100).round(2) : nil
end

def gauge(name, value, tags = {})
  Appsignal.set_gauge(name, value, tags) unless value.nil?
end

def workload(pod)
  owner = (pod.dig("metadata", "ownerReferences") || []).first
  name = owner ? owner["name"] : pod.dig("metadata", "name")
  # ReplicaSet "orders-web-6c95747f45" -> Deployment "orders-web"
  owner && owner["kind"] == "ReplicaSet" ? name.sub(/-[a-z0-9]{8,10}\z/, "") : name
end

# Previous cAdvisor CFS counters per pod, to turn totals into a rate.
$cfs = {}

def collect
  nodes = Kube.get("/api/v1/nodes")["items"]
  pods = Kube.get("/api/v1/pods")["items"]
  scheduled = pods.select { |p| p.dig("spec", "nodeName") && %w[Pending Running].include?(p.dig("status", "phase")) }
  cluster = Hash.new(0.0)

  gauge("k8s_cluster_pods_pending", pods.count { |p| p.dig("status", "phase") == "Pending" && p.dig("spec", "nodeName").nil? })
  gauge("k8s_cluster_nodes", nodes.size)

  nodes.each do |node|
    name = node.dig("metadata", "name")
    tags = { node_name: name }
    alloc = node.dig("status", "allocatable")
    on_node = scheduled.select { |p| p.dig("spec", "nodeName") == name }
    containers = on_node.flat_map { |p| p.dig("spec", "containers") }

    a_cpu = cpu(alloc["cpu"])
    a_mem = bytes(alloc["memory"])
    a_pods = alloc["pods"].to_f
    req_cpu = containers.sum { |c| cpu(c.dig("resources", "requests", "cpu")) }
    req_mem = containers.sum { |c| bytes(c.dig("resources", "requests", "memory")) }
    lim_cpu = containers.sum { |c| cpu(c.dig("resources", "limits", "cpu")) }
    lim_mem = containers.sum { |c| bytes(c.dig("resources", "limits", "memory")) }

    stats = Kube.get("/api/v1/nodes/#{name}/proxy/stats/summary")
    used_cpu = stats.dig("node", "cpu", "usageNanoCores").to_f / 1e9
    used_mem = stats.dig("node", "memory", "workingSetBytes").to_f
    fs = stats.dig("node", "fs") || {}

    gauge("k8s_node_cpu_allocatable_cores", a_cpu, tags)
    gauge("k8s_node_memory_allocatable_bytes", a_mem, tags)
    gauge("k8s_node_pods_allocatable", a_pods, tags)
    gauge("k8s_node_pods_running", on_node.size, tags)
    gauge("k8s_node_pods_used_pct", pct(on_node.size, a_pods), tags)
    gauge("k8s_node_cpu_requested_cores", req_cpu, tags)
    gauge("k8s_node_memory_requested_bytes", req_mem, tags)
    gauge("k8s_node_cpu_requested_pct", pct(req_cpu, a_cpu), tags)
    gauge("k8s_node_memory_requested_pct", pct(req_mem, a_mem), tags)
    gauge("k8s_node_cpu_limits_pct", pct(lim_cpu, a_cpu), tags)
    gauge("k8s_node_memory_limits_pct", pct(lim_mem, a_mem), tags)
    gauge("k8s_node_cpu_used_pct", pct(used_cpu, a_cpu), tags)
    gauge("k8s_node_memory_used_pct", pct(used_mem, a_mem), tags)
    gauge("k8s_node_fs_used_pct", pct(fs["usedBytes"], fs["capacityBytes"]), tags)

    (node.dig("status", "conditions") || []).each do |c|
      next unless %w[Ready MemoryPressure DiskPressure PIDPressure].include?(c["type"])
      gauge("k8s_node_condition", c["status"] == "True" ? 1 : 0, tags.merge(condition: c["type"]))
    end

    cluster[:a_cpu] += a_cpu
    cluster[:a_mem] += a_mem
    cluster[:req_cpu] += req_cpu
    cluster[:req_mem] += req_mem
    cluster[:used_cpu] += used_cpu
    cluster[:used_mem] += used_mem
    cluster[:ready] += 1 if node.dig("status", "conditions")&.any? { |c| c["type"] == "Ready" && c["status"] == "True" }

    usage = (stats["pods"] || []).to_h do |p|
      [p.dig("podRef", "uid"), [p.dig("cpu", "usageNanoCores").to_f / 1e9, p.dig("memory", "workingSetBytes").to_f]]
    end
    throttled = cfs_throttling(name)

    on_node.each do |pod|
      ptags = { node_name: name, pod_namespace: pod.dig("metadata", "namespace"),
                pod_name: pod.dig("metadata", "name"), workload: workload(pod) }
      cs = pod.dig("spec", "containers")
      p_req_cpu = cs.sum { |c| cpu(c.dig("resources", "requests", "cpu")) }
      p_lim_cpu = cs.sum { |c| cpu(c.dig("resources", "limits", "cpu")) }
      p_req_mem = cs.sum { |c| bytes(c.dig("resources", "requests", "memory")) }
      p_lim_mem = cs.sum { |c| bytes(c.dig("resources", "limits", "memory")) }
      p_cpu, p_mem = usage[pod.dig("metadata", "uid")]
      statuses = pod.dig("status", "containerStatuses") || []

      gauge("k8s_pod_cpu_request_cores", p_req_cpu, ptags)
      gauge("k8s_pod_cpu_limit_cores", p_lim_cpu, ptags) if p_lim_cpu.positive?
      gauge("k8s_pod_memory_request_bytes", p_req_mem, ptags)
      gauge("k8s_pod_memory_limit_bytes", p_lim_mem, ptags) if p_lim_mem.positive?
      gauge("k8s_pod_cpu_request_pct", pct(p_cpu, p_req_cpu), ptags) if p_cpu
      gauge("k8s_pod_cpu_limit_pct", pct(p_cpu, p_lim_cpu), ptags) if p_cpu
      gauge("k8s_pod_memory_request_pct", pct(p_mem, p_req_mem), ptags) if p_mem
      gauge("k8s_pod_memory_limit_pct", pct(p_mem, p_lim_mem), ptags) if p_mem
      gauge("k8s_pod_cpu_throttled_pct", throttled[[ptags[:pod_namespace], ptags[:pod_name]]], ptags)
      gauge("k8s_pod_restarts", statuses.sum { |s| s["restartCount"].to_i }, ptags)
      gauge("k8s_pod_oom_killed", statuses.count { |s| s.dig("lastState", "terminated", "reason") == "OOMKilled" }, ptags)
    end
  end

  gauge("k8s_cluster_nodes_ready", cluster[:ready])
  gauge("k8s_cluster_cpu_allocatable_cores", cluster[:a_cpu])
  gauge("k8s_cluster_memory_allocatable_bytes", cluster[:a_mem])
  gauge("k8s_cluster_cpu_requested_pct", pct(cluster[:req_cpu], cluster[:a_cpu]))
  gauge("k8s_cluster_memory_requested_pct", pct(cluster[:req_mem], cluster[:a_mem]))
  gauge("k8s_cluster_cpu_used_pct", pct(cluster[:used_cpu], cluster[:a_cpu]))
  gauge("k8s_cluster_memory_used_pct", pct(cluster[:used_mem], cluster[:a_mem]))
  # Headroom = what can still be scheduled, the number to plan hardware on.
  gauge("k8s_cluster_cpu_unrequested_cores", cluster[:a_cpu] - cluster[:req_cpu])
  gauge("k8s_cluster_memory_unrequested_bytes", cluster[:a_mem] - cluster[:req_mem])
  LOG.info("Reported capacity for #{nodes.size} nodes, #{scheduled.size} pods")
end

# Share of CPU periods in which a pod hit its CPU limit, since the last run.
def cfs_throttling(node)
  totals = Hash.new { |h, k| h[k] = [0.0, 0.0] }
  Kube.get("/api/v1/nodes/#{node}/proxy/metrics/cadvisor", raw: true).each_line do |line|
    next unless line.start_with?("container_cpu_cfs_")
    kind = line.start_with?("container_cpu_cfs_throttled_periods_total") ? 0 : (line.start_with?("container_cpu_cfs_periods_total") ? 1 : nil)
    next unless kind
    ns = line[/namespace="([^"]*)"/, 1]
    pod = line[/pod="([^"]*)"/, 1]
    next if ns.to_s.empty? || pod.to_s.empty? || line.include?('container=""')
    totals[[ns, pod]][kind] += line.split.last.to_f
  end
  totals.to_h do |key, (throttled, periods)|
    prev_t, prev_p = $cfs[key]
    $cfs[key] = [throttled, periods]
    [key, prev_p && periods > prev_p ? pct(throttled - prev_t, periods - prev_p) : nil]
  end
rescue StandardError => e
  LOG.warn("cAdvisor throttling unavailable for #{node}: #{e.message}")
  {}
end

loop do
  begin
    collect
  rescue StandardError => e
    LOG.error("Collection failed: #{e.class}: #{e.message}")
  end
  sleep INTERVAL
end
