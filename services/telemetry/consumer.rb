# Telemetry consumer: subscribes to silo readings, sensor status and order
# dispatch messages over MQTT (QoS 1, persistent session), stores the latest
# silo levels in Postgres and reports consumer-side MQTT metrics.
#
# Every 15 minutes (at :05, :20, :35 and :50) it pauses for PAUSE_SECONDS, as
# if blocked on a slow database. Messages pile up in its RabbitMQ queue and
# end-to-end latency climbs, then it catches up: a backlog you can watch.
require "json"
require "logger"
require "mqtt"
require "mysql2"
require "pg"
require "appsignal"

Appsignal.start
$stdout.sync = true
LOG = Logger.new($stdout)
CLIENT_ID = "telemetry-consumer"
PAUSE_SECONDS = Integer(ENV.fetch("PAUSE_SECONDS", "90"))

def paused?
  ((Time.now.to_i - 300) % 900) < PAUSE_SECONDS
end

def db
  @db ||= PG.connect(ENV.fetch("DATABASE_URL")).tap do |conn|
    conn.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS silo_levels (
        device text PRIMARY KEY, site text NOT NULL, sku text NOT NULL,
        level_pct numeric NOT NULL, tonnes numeric NOT NULL, updated_at timestamptz NOT NULL
      )
    SQL
  end
end

# Full reading history lives in MySQL (Postgres only keeps the latest level).
def mysql_client
  Mysql2::Client.new(host: ENV.fetch("MYSQL_HOST", "mysql"), username: ENV.fetch("MYSQL_USER"),
    password: ENV.fetch("MYSQL_PASSWORD"), database: ENV.fetch("MYSQL_DATABASE", "telemetry"), reconnect: true)
end

def mysql
  @mysql ||= mysql_client.tap do |c|
    c.query(<<~SQL)
      CREATE TABLE IF NOT EXISTS silo_readings (
        id BIGINT AUTO_INCREMENT PRIMARY KEY, device VARCHAR(64) NOT NULL, site VARCHAR(32) NOT NULL,
        sku VARCHAR(32) NOT NULL, level_pct DECIMAL(5,1) NOT NULL, tonnes DECIMAL(8,1) NOT NULL,
        read_at DATETIME(3) NOT NULL, KEY idx_read_at (read_at)
      )
    SQL
  end
end

# Every minute: an hourly rollup (uses the read_at index) and a "lowest
# readings" report that scans the whole table, so the MySQL dashboard has a
# slow query shape to point at.
def rollups
  client = nil
  loop do
    sleep 60
    begin
      client ||= mysql_client
      client.query("SELECT site, sku, avg(level_pct), min(level_pct) FROM silo_readings WHERE read_at > now() - INTERVAL 1 HOUR GROUP BY site, sku").to_a
      client.query("SELECT device, level_pct, read_at FROM silo_readings ORDER BY level_pct, read_at DESC LIMIT 20").to_a
    rescue StandardError => e
      LOG.warn("MySQL rollup failed: #{e.class}: #{e.message}")
      client = nil
    end
  end
end

$last_seen = {}
$online = {}

def report_devices
  now = Time.now
  Appsignal.set_gauge("mqtt_devices_online", $online.count { |_, up| up })
  Appsignal.set_gauge("mqtt_devices_reporting", $last_seen.count { |_, t| now - t < 60 })
  $last_seen.each { |device, t| Appsignal.set_gauge("mqtt_device_last_seen_seconds", (now - t).round, device: device) }
end

def handle(topic, payload)
  data = JSON.parse(payload)
  kind = topic.split("/").last
  kind = "dispatch" if topic.start_with?("ijzerhaven/dispatch/")
  Appsignal.increment_counter("mqtt_consumer_messages", 1, topic_type: kind)

  case kind
  when "level"
    latency = Time.now.to_f * 1000 - data["ts"].to_i
    Appsignal.add_distribution_value("mqtt_e2e_latency_ms", latency, topic_type: "level")
    $last_seen[data["device"]] = Time.now
    db.exec_params(<<~SQL, data.values_at("device", "site", "sku", "level_pct", "tonnes"))
      INSERT INTO silo_levels (device, site, sku, level_pct, tonnes, updated_at)
      VALUES ($1, $2, $3, $4, $5, now())
      ON CONFLICT (device) DO UPDATE SET level_pct = $4, tonnes = $5, updated_at = now()
    SQL
    Appsignal.set_gauge("silo_level_pct", data["level_pct"].to_f, site: data["site"], sku: data["sku"])
    @insert_reading ||= mysql.prepare("INSERT INTO silo_readings (device, site, sku, level_pct, tonnes, read_at) VALUES (?, ?, ?, ?, ?, ?)")
    @insert_reading.execute(*data.values_at("device", "site", "sku", "level_pct", "tonnes"), Time.at(data["ts"].to_i / 1000.0).utc)
  when "status"
    $online[data["device"]] = data["state"] == "online"
    Appsignal.increment_counter("mqtt_device_status_changes", 1, state: data["state"])
  when "dispatch"
    latency = Time.now.to_f * 1000 - data["ts"].to_i
    Appsignal.add_distribution_value("mqtt_e2e_latency_ms", latency, topic_type: "dispatch")
    LOG.info("Dispatch queued for #{data["order_reference"]} (#{data["quantity"]} t #{data["sku"]})")
  end
rescue StandardError => e
  Appsignal.increment_counter("mqtt_consumer_errors", 1, error: e.class.name)
  LOG.error("Failed to handle #{topic}: #{e.class}: #{e.message}")
end

reporter = Thread.new { loop { report_devices rescue nil; sleep 15 } }
Thread.new { rollups }

loop do
  client = MQTT::Client.new(
    host: ENV.fetch("MQTT_HOST", "rabbitmq"), port: 1883,
    username: ENV.fetch("MQTT_USERNAME"), password: ENV.fetch("MQTT_PASSWORD"),
    client_id: CLIENT_ID, clean_session: false, keep_alive: 30
  )
  client.connect
  client.subscribe("ijzerhaven/+/silo/+/level" => 1, "ijzerhaven/+/silo/+/status" => 1, "ijzerhaven/dispatch/#" => 1)
  Appsignal.increment_counter("mqtt_client_connects", 1, client_type: "consumer")
  LOG.info("Subscribed as #{CLIENT_ID}")
  loop do
    if paused?
      LOG.info("Paused (simulated slow database), letting the queue back up") unless @was_paused
      @was_paused = true
      sleep 1
      next
    end
    LOG.info("Resumed, draining backlog") if @was_paused
    @was_paused = false
    topic, payload = client.get
    handle(topic, payload)
  end
rescue StandardError => e
  Appsignal.increment_counter("mqtt_client_errors", 1, client_type: "consumer", error: e.class.name)
  LOG.warn("Consumer connection lost: #{e.class}: #{e.message}")
  client&.disconnect rescue nil
  sleep 5
end
