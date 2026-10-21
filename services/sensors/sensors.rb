# Simulated silo level sensors at two Ijzerhaven sites, one MQTT client each.
#
# Each sensor publishes its fill level (QoS 1) every PUBLISH_SECONDS to
#   ijzerhaven/<site>/silo/<sku>/level
# and keeps a retained "online" status with a last will of "offline" on
#   ijzerhaven/<site>/silo/<sku>/status
# Now and then a sensor drops off the network without saying goodbye (the
# broker publishes its will) and reconnects a little later, like real
# hardware on a factory Wi-Fi.
require "json"
require "logger"
require "mqtt"
require "appsignal"

Appsignal.start
$stdout.sync = true
LOG = Logger.new($stdout)

SITES = %w[rotterdam delft].freeze
SKUS = %w[HRC-S235 AL-INGOT-99 CU-CATH-A NI-BRIQ ZN-SHG PP-H350].freeze
PUBLISH_SECONDS = Float(ENV.fetch("PUBLISH_SECONDS", "15"))
DROP_CHANCE = Float(ENV.fetch("DROP_CHANCE_PER_PUBLISH", "0.01"))

class Sensor
  def initialize(site, sku)
    @site = site
    @sku = sku
    @id = "silo-#{site}-#{sku.downcase}"
    @base = "ijzerhaven/#{site}/silo/#{sku}"
    @level = rand(30.0..90.0)
  end

  def run
    loop do
      client = connect
      loop do
        publish_reading(client)
        if rand < DROP_CHANCE
          drop(client)
          break
        end
        sleep PUBLISH_SECONDS * rand(0.8..1.2)
      end
    rescue StandardError => e
      Appsignal.increment_counter("mqtt_client_errors", 1, client_type: "sensor", error: e.class.name)
      LOG.warn("#{@id}: #{e.class}: #{e.message}")
      sleep 5
    end
  end

  private

  def connect
    client = MQTT::Client.new(
      host: ENV.fetch("MQTT_HOST", "rabbitmq"), port: 1883,
      username: ENV.fetch("MQTT_USERNAME"), password: ENV.fetch("MQTT_PASSWORD"),
      client_id: @id, clean_session: true, keep_alive: 30
    )
    client.set_will("#{@base}/status", JSON.generate(device: @id, state: "offline"), true, 1)
    client.connect
    client.publish("#{@base}/status", JSON.generate(device: @id, state: "online"), true, 1)
    Appsignal.increment_counter("mqtt_client_connects", 1, client_type: "sensor", site: @site)
    client
  end

  def publish_reading(client)
    # Silos drain as material ships, and get refilled by a delivery now and then.
    @level -= rand(0.2..1.5)
    @level = rand(85.0..98.0) if @level < 12
    payload = JSON.generate(device: @id, site: @site, sku: @sku, level_pct: @level.round(1),
      tonnes: (@level * 4.2).round(1), ts: (Time.now.to_f * 1000).to_i)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.publish("#{@base}/level", payload, false, 1) # blocks until PUBACK
    ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    tags = { client_type: "sensor", site: @site }
    Appsignal.increment_counter("mqtt_client_published", 1, tags.merge(topic_type: "level"))
    Appsignal.add_distribution_value("mqtt_client_puback_ms", ms, tags)
    Appsignal.add_distribution_value("mqtt_client_payload_bytes", payload.bytesize, tags.merge(topic_type: "level"))
  end

  # Close the socket without a DISCONNECT packet, so the broker fires the will.
  def drop(client)
    Appsignal.increment_counter("mqtt_client_dropped", 1, client_type: "sensor", site: @site)
    LOG.info("#{@id}: dropping off the network")
    client.disconnect(false)
    sleep rand(20..60)
  end
end

SITES.product(SKUS).map { |site, sku| Thread.new { Sensor.new(site, sku).run } }.each(&:join)
