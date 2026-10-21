# Simulated buyers browsing the catalogue and placing orders, forever.
require "json"
require "net/http"

# Same app, four ways in: straight to the service, or through HAProxy, the
# nginx ingress controller or Traefik, so each one has traffic to monitor.
ENTRYPOINTS = {
  "direct" => [URI(ENV.fetch("ORDERS_URL", "http://orders-web:3000")), nil],
  "haproxy" => [URI("http://haproxy:8080"), nil],
  "ingress-nginx" => [URI("http://ingress-nginx-controller.ingress-nginx"), "orders.ijzerhaven.local"],
  "traefik" => [URI("http://traefik.traefik"), "orders.ijzerhaven.local"]
}.freeze
RPS = Float(ENV.fetch("REQUESTS_PER_SECOND", "4"))
THREADS = 4

CUSTOMERS = [
  "Delft Steelworks", "Rotterdam Fabrication BV", "Eindhoven Precision Parts", "Twente Plastics",
  "Zeeland Shipyards", "Utrecht Construction Group", "Groningen Cable Co", "Maas Foundry"
].freeze
SKUS = %w[HRC-S235 AL-INGOT-99 CU-CATH-A NI-BRIQ ZN-SHG PP-H350 SI-SAND-40 CEM-I-52].freeze

$stdout.sync = true

def call(request, customer)
  name = ENTRYPOINTS.keys.sample
  uri, host = ENTRYPOINTS[name]
  request["X-Customer"] = customer
  request["X-Entrypoint"] = name
  request["Content-Type"] = "application/json"
  request["Host"] = host if host
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 10) { |http| http.request(request) }
  puts "#{Time.now.utc.strftime("%H:%M:%S")} #{name} #{request.method} #{request.path} -> #{response.code}"
  response
rescue StandardError => e
  puts "#{Time.now.utc.strftime("%H:%M:%S")} #{name} #{request.method} #{request.path} !! #{e.class}: #{e.message}"
  sleep 1
  nil
end

THREADS.times.map do
  Thread.new do
    loop do
      customer = CUSTOMERS.sample
      roll = rand
      if roll < 0.15
        call(Net::HTTP::Get.new("/"), customer)
      elsif roll < 0.35
        call(Net::HTTP::Get.new("/api/materials"), customer)
      else
        order = {
          customer: customer,
          sku: SKUS.sample,
          quantity: rand(1..25),
          payment_method: rand < 0.75 ? "card" : "invoice"
        }
        post = Net::HTTP::Post.new("/api/orders")
        post.body = JSON.generate(order)
        response = call(post, customer)
        # Some buyers check on their order straight away.
        if response && rand < 0.3 && (ref = JSON.parse(response.body)["reference"] rescue nil)
          sleep rand(1..4)
          call(Net::HTTP::Get.new("/api/orders/#{ref}"), customer)
        end
      end
      sleep(THREADS / RPS * rand(0.5..1.5))
    end
  end
end.each(&:join)
