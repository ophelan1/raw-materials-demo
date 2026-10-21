# Prometheus bridge: scrapes Prometheus /metrics endpoints and forwards the
# series that matter to AppSignal as custom metrics.
#
# Targets come from three places, all configured in bridge.yml:
#   - static URLs (control plane components on the node this pod runs on),
#   - every node's kubelet, through the API server proxy,
#   - discovery: pods and services annotated prometheus.io/scrape: "true",
#     the same convention Prometheus' kubernetes_sd uses.
# Each job has rules that pick metrics, keep a few labels, and say how to
# aggregate: gauge (sum), counter (per-interval delta), or histogram (mean and
# p95 from _sum/_count/_bucket deltas). Jobs without rules can forward a
# capped passthrough of their gauges, which is how a new internal exporter
# (like Keess) gets onto a dashboard with one annotation.
require "json"
require "logger"
require "net/http"
require "openssl"
require "yaml"
require "appsignal"

Appsignal.start
$stdout.sync = true
LOG = Logger.new($stdout)
CONFIG = YAML.safe_load_file(ENV.fetch("BRIDGE_CONFIG", "/etc/bridge/bridge.yml"))
CLUSTER = CONFIG.fetch("cluster")
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://#{ENV.fetch("KUBERNETES_SERVICE_HOST")}:#{ENV.fetch("KUBERNETES_SERVICE_PORT")}"

def fetch(url, auth: false, insecure: false)
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 3
  http.read_timeout = 10
  if uri.scheme == "https"
    http.use_ssl = true
    if insecure
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    else
      http.ca_file = "#{SA}/ca.crt"
    end
  end
  request = Net::HTTP::Get.new(uri.request_uri)
  request["Authorization"] = "Bearer #{File.read("#{SA}/token")}" if auth
  response = http.request(request)
  raise "#{response.code} from #{url}" unless response.code == "200"
  response.body
end

def kube(path) = JSON.parse(fetch("#{API}#{path}", auth: true))

# Prometheus text format into [[name, labels, value], ...].
def parse(text)
  text.each_line.filter_map do |line|
    next if line.start_with?("#") || line.strip.empty?
    m = line.match(/\A([a-zA-Z_:][\w:]*)(?:\{(.*)\})?\s+(\S+)/) or next
    labels = m[2].to_s.scan(/(\w+)="((?:[^"\\]|\\.)*)"/).to_h
    value = Float(m[3]) rescue next
    [m[1], labels, value]
  end
end

# Derived labels: "code_class" from "code" (200 -> 2xx) and the like.
def label_value(labels, spec)
  name, from = spec.is_a?(Hash) ? [spec["as"], spec["from"]] : [spec, spec]
  value = labels[from].to_s
  value = "#{value[0]}xx" if spec.is_a?(Hash) && spec["transform"] == "class" && value.match?(/\A\d/)
  [name, value]
end

$previous = {}
def delta(key, value)
  prev = $previous[key]
  $previous[key] = value
  prev && value >= prev ? value - prev : nil
end

def quantile(q, buckets)
  total = buckets.last&.last.to_f
  return nil unless total.positive?
  rank = q * total
  prev_le, prev_count = 0.0, 0.0
  buckets.each do |le, count|
    if count >= rank
      return prev_le if le.infinite?
      return le if count == prev_count
      return prev_le + (le - prev_le) * (rank - prev_count) / (count - prev_count)
    end
    prev_le, prev_count = le, count
  end
  prev_le
end

def apply_rules(job, series, base_tags)
  forwarded = 0
  (job["rules"] || []).each do |rule|
    name, type, scale = rule["metric"], rule.fetch("type"), rule.fetch("scale", 1).to_f
    match = (rule["match"] || {}).transform_values { |v| Regexp.new(v) }
    picked = lambda do |metric_name|
      series.select { |n, l, _| n == metric_name && match.all? { |k, re| l[k].to_s.match?(re) } }
    end
    group = lambda do |labels|
      base_tags.merge((rule["labels"] || []).to_h { |spec| label_value(labels, spec) })
    end

    case type
    when "gauge"
      picked.(name).group_by { |_, l, _| group.(l) }.each do |tags, rows|
        Appsignal.set_gauge(rule["as"], rows.sum { |r| r[2] } * scale, tags)
        forwarded += 1
      end
    when "counter"
      picked.(name).group_by { |_, l, _| group.(l) }.each do |tags, rows|
        d = delta([job["name"], rule["as"], tags], rows.sum { |r| r[2] })
        Appsignal.increment_counter(rule["as"], d * scale, tags) if d
        forwarded += 1
      end
    when "histogram"
      sums = picked.("#{name}_sum").group_by { |_, l, _| group.(l) }
      counts = picked.("#{name}_count").group_by { |_, l, _| group.(l) }
      buckets = picked.("#{name}_bucket").group_by { |_, l, _| group.(l) }
      counts.each do |tags, rows|
        dc = delta([job["name"], rule["as"], :count, tags], rows.sum { |r| r[2] })
        ds = delta([job["name"], rule["as"], :sum, tags], sums.fetch(tags, []).sum { |r| r[2] })
        next unless dc && ds && dc.positive?
        Appsignal.set_gauge("#{rule["as"]}_mean", ds / dc * scale, tags)
        by_le = buckets.fetch(tags, []).group_by { |_, l, _| l["le"] == "+Inf" ? Float::INFINITY : l["le"].to_f }
        deltas = by_le.sort_by(&:first).filter_map do |le, rs|
          d = delta([job["name"], rule["as"], :bucket, tags, le], rs.sum { |r| r[2] })
          [le, d] if d
        end
        p95 = quantile(0.95, deltas)
        Appsignal.set_gauge("#{rule["as"]}_p95", p95 * scale, tags) if p95
        forwarded += 1
      end
    end
  end

  if job["passthrough"]
    series.select { |n, _, _| n.match?(Regexp.new(job["passthrough"]["match"])) }
      .first(job["passthrough"].fetch("max_series", 50)).each do |n, l, v|
        Appsignal.set_gauge("prom_#{n}", v, base_tags.merge(l.slice(*job["passthrough"].fetch("labels", []))))
        forwarded += 1
      end
  end
  forwarded
end

# Every target to scrape this round: [job, url, extra tags, scrape options].
def targets
  list = []
  jobs = CONFIG["jobs"].to_h { |j| [j["name"], j] }
  jobs.each_value do |job|
    if job["url"]
      list << [job, job["url"], {}]
    elsif job["per_node"]
      kube("/api/v1/nodes")["items"].each do |node|
        n = node.dig("metadata", "name")
        list << [job, "#{API}/api/v1/nodes/#{n}/proxy#{job.fetch("path", "/metrics")}", { node_name: n }]
      end
    end
  end

  # Annotation discovery. prometheus.io/job picks the rules; it defaults to the
  # pod's app label, or the service name.
  kube("/api/v1/pods")["items"].each do |pod|
    ann = pod.dig("metadata", "annotations") || {}
    next unless ann["prometheus.io/scrape"] == "true" && pod.dig("status", "phase") == "Running" && pod.dig("status", "podIP")
    name = ann["prometheus.io/job"] || pod.dig("metadata", "labels", "app") || pod.dig("metadata", "name")
    job = jobs[name] || { "name" => name, "passthrough" => CONFIG["default_passthrough"] }
    url = "http://#{pod.dig("status", "podIP")}:#{ann.fetch("prometheus.io/port", "9090")}#{ann.fetch("prometheus.io/path", "/metrics")}"
    list << [job, url, { pod_namespace: pod.dig("metadata", "namespace"), pod_name: pod.dig("metadata", "name") }]
  end
  kube("/api/v1/services")["items"].each do |svc|
    ann = svc.dig("metadata", "annotations") || {}
    next unless ann["prometheus.io/scrape"] == "true"
    ns, sname = svc.dig("metadata", "namespace"), svc.dig("metadata", "name")
    name = ann["prometheus.io/job"] || sname
    job = jobs[name] || { "name" => name, "passthrough" => CONFIG["default_passthrough"] }
    eps = kube("/api/v1/namespaces/#{ns}/endpoints/#{sname}")
    (eps["subsets"] || []).each do |subset|
      (subset["addresses"] || []).each do |addr|
        pod = addr.dig("targetRef", "name") || addr["ip"]
        url = "http://#{addr["ip"]}:#{ann.fetch("prometheus.io/port", "9090")}#{ann.fetch("prometheus.io/path", "/metrics")}"
        list << [job, url, { pod_namespace: ns, pod_name: pod }]
      end
    end
  end
  list
end

loop do
  started = Time.now
  summary = Hash.new(0)
  begin
    targets.each do |job, url, extra|
      base = { cluster: CLUSTER, job: job["name"] }.merge(job["per_instance_tags"] == false ? {} : extra)
      body = fetch(url, auth: job.fetch("auth", url.start_with?(API)), insecure: job.fetch("insecure", false))
      summary[job["name"]] += apply_rules(job, parse(body), base)
      Appsignal.set_gauge("prometheus_target_up", 1, { cluster: CLUSTER, job: job["name"] })
    rescue StandardError => e
      Appsignal.set_gauge("prometheus_target_up", 0, { cluster: CLUSTER, job: job["name"] })
      LOG.warn("Scrape failed for #{job["name"]} #{url}: #{e.class}: #{e.message}")
    end
  rescue StandardError => e
    LOG.error("Target discovery failed: #{e.class}: #{e.message}")
  end
  Appsignal.set_gauge("prometheus_bridge_scrape_seconds", Time.now - started, { cluster: CLUSTER })
  LOG.info("Forwarded #{summary.values.sum} series: #{summary.map { |k, v| "#{k}=#{v}" }.join(" ")}")
  sleep CONFIG.fetch("interval", 30)
end
