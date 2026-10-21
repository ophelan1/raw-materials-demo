# MQTT broker metrics exporter for RabbitMQ.
#
# Since RabbitMQ 3.12 the management API no longer reports MQTT message rates,
# so rates come from the Prometheus endpoint's global counters (labelled
# protocol="mqtt311"). Per-subscriber backlog and per-connection traffic still
# come from the management API. Cumulative counters are sent to AppSignal as
# per-interval deltas (increment_counter); everything else as gauges.
require "json"
require "logger"
require "net/http"
require "appsignal"

Appsignal.start
$stdout.sync = true
LOG = Logger.new($stdout)
INTERVAL = Integer(ENV.fetch("INTERVAL_SECONDS", "30"))
HOST = ENV.fetch("RABBITMQ_HOST", "rabbitmq")
USER = ENV.fetch("RABBITMQ_USERNAME")
PASS = ENV.fetch("RABBITMQ_PASSWORD")

def http_get(port, path, auth: false)
  request = Net::HTTP::Get.new(path)
  request.basic_auth(USER, PASS) if auth
  response = Net::HTTP.start(HOST, port, open_timeout: 5, read_timeout: 10) { |h| h.request(request) }
  raise "GET #{path}: #{response.code}" unless response.code == "200"
  response.body
end

def api(path) = JSON.parse(http_get(15672, "/api#{path}", auth: true))

# Prometheus text format into { [name, {labels}] => value }.
def prometheus
  http_get(15692, "/metrics").each_line.with_object({}) do |line, out|
    next if line.start_with?("#") || line.strip.empty?
    m = line.match(/\A([a-zA-Z_:][\w:]*)(?:\{([^}]*)\})?\s+(\S+)/) or next
    labels = m[2].to_s.scan(/(\w+)="([^"]*)"/).to_h
    out[[m[1], labels]] = m[3].to_f
  end
end

def sum(prom, name, **labels)
  prom.select { |(n, l), _| n == name && labels.all? { |k, v| l[k.to_s] == v } }.values.sum
end

$previous = {}
def counter(name, value, tags = {})
  key = [name, tags]
  prev = $previous[key]
  $previous[key] = value
  Appsignal.increment_counter(name, value - prev, tags) if prev && value >= prev
end

def gauge(name, value, tags = {})
  Appsignal.set_gauge(name, value.to_f, tags) unless value.nil?
end

def pct(part, whole)
  whole.to_f.positive? ? (part.to_f / whole * 100).round(2) : nil
end

def collect
  prom = prometheus
  mqtt = "mqtt311"

  # Message flow through the broker for MQTT clients.
  counter("mqtt_broker_messages", sum(prom, "rabbitmq_global_messages_received_total", protocol: mqtt), stage: "received")
  counter("mqtt_broker_messages", sum(prom, "rabbitmq_global_messages_routed_total", protocol: mqtt), stage: "routed")
  counter("mqtt_broker_messages", sum(prom, "rabbitmq_global_messages_delivered_total", protocol: mqtt), stage: "delivered")
  counter("mqtt_broker_messages", sum(prom, "rabbitmq_global_messages_acknowledged_total", protocol: mqtt), stage: "acknowledged")
  counter("mqtt_broker_messages", sum(prom, "rabbitmq_global_messages_confirmed_total", protocol: mqtt), stage: "puback_sent")
  counter("mqtt_broker_messages_unroutable", sum(prom, "rabbitmq_global_messages_unroutable_dropped_total", protocol: mqtt) +
    sum(prom, "rabbitmq_global_messages_unroutable_returned_total", protocol: mqtt))
  counter("mqtt_broker_messages_dropped_overload", sum(prom, "rabbitmq_global_messages_dead_lettered_maxlen_total"))
  gauge("mqtt_broker_publishers", sum(prom, "rabbitmq_global_publishers", protocol: mqtt))
  gauge("mqtt_broker_consumers", sum(prom, "rabbitmq_global_consumers", protocol: mqtt))

  # Connection churn: opened/closed across all protocols (MQTT is nearly all of it here).
  counter("mqtt_broker_connections_opened", sum(prom, "rabbitmq_connections_opened_total"))
  counter("mqtt_broker_connections_closed", sum(prom, "rabbitmq_connections_closed_total"))

  # Broker resources and alarms.
  mem = sum(prom, "rabbitmq_process_resident_memory_bytes")
  mem_limit = sum(prom, "rabbitmq_resident_memory_limit_bytes")
  disk = sum(prom, "rabbitmq_disk_space_available_bytes")
  disk_limit = sum(prom, "rabbitmq_disk_space_available_limit_bytes")
  gauge("mqtt_broker_memory_bytes", mem)
  gauge("mqtt_broker_memory_watermark_pct", pct(mem, mem_limit))
  gauge("mqtt_broker_disk_free_bytes", disk)
  gauge("mqtt_broker_disk_headroom_ratio", disk_limit.positive? ? (disk / disk_limit).round(2) : nil)
  gauge("mqtt_broker_fds_used_pct", pct(sum(prom, "rabbitmq_process_open_fds"), sum(prom, "rabbitmq_process_max_fds")))
  gauge("mqtt_broker_erlang_processes_used_pct",
    pct(sum(prom, "rabbitmq_erlang_processes_used"), sum(prom, "rabbitmq_erlang_processes_limit")))
  gauge("mqtt_broker_alarm", sum(prom, "rabbitmq_alarms_memory_used_watermark"), alarm: "memory")
  gauge("mqtt_broker_alarm", sum(prom, "rabbitmq_alarms_free_disk_space_watermark"), alarm: "disk")
  gauge("mqtt_broker_alarm", sum(prom, "rabbitmq_alarms_file_descriptor_limit"), alarm: "file_descriptors")

  # MQTT connections and their network traffic.
  conns = api("/connections?columns=name,protocol,client_properties,recv_oct,send_oct,user")
    .select { |c| c["protocol"].to_s.start_with?("MQTT") }
  gauge("mqtt_connections", conns.size)
  conns.group_by { |c| c["protocol"] }.each { |proto, cs| gauge("mqtt_connections_by_protocol", cs.size, protocol: proto) }
  bytes_in = sum(prom, "rabbitmq_connection_incoming_bytes_total")
  bytes_out = sum(prom, "rabbitmq_connection_outgoing_bytes_total")
  counter("mqtt_broker_bytes", bytes_in, direction: "in") if bytes_in.positive?
  counter("mqtt_broker_bytes", bytes_out, direction: "out") if bytes_out.positive?

  # Subscriber queues (one per MQTT session with a QoS 1 subscription): backlog.
  queues = api("/queues?columns=name,messages,messages_ready,messages_unacknowledged,consumers")
    .select { |q| q["name"].start_with?("mqtt-subscription-") }
  queues.each do |q|
    tags = { client_id: q["name"].delete_prefix("mqtt-subscription-").sub(/qos[01]\z/, "") }
    gauge("mqtt_subscriber_backlog", q["messages_ready"], tags)
    gauge("mqtt_subscriber_inflight", q["messages_unacknowledged"], tags)
    gauge("mqtt_subscriber_online", q["consumers"].to_i.positive? ? 1 : 0, tags)
  end
  gauge("mqtt_backlog_total", queues.sum { |q| q["messages"].to_i })
  gauge("mqtt_sessions", queues.size)

  LOG.info("Reported MQTT broker metrics (#{conns.size} MQTT connections, #{queues.size} subscriber queues)")
end

loop do
  begin
    collect
  rescue StandardError => e
    LOG.error("Collection failed: #{e.class}: #{e.message}")
  end
  sleep INTERVAL
end
