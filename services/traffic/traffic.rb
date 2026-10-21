# Simulated buyers browsing the catalogue and placing orders, forever.
require "json"
require "net/http"

BASE = URI(ENV.fetch("ORDERS_URL", "http://orders-web:3000"))
RPS = Float(ENV.fetch("REQUESTS_PER_SECOND", "4"))
THREADS = 4

CUSTOMERS = [
  "Delft Steelworks", "Rotterdam Fabrication BV", "Eindhoven Precision Parts", "Twente Plastics",
  "Zeeland Shipyards", "Utrecht Construction Group", "Groningen Cable Co", "Maas Foundry"
].freeze
SKUS = %w[HRC-S235 AL-INGOT-99 CU-CATH-A NI-BRIQ ZN-SHG PP-H350 SI-SAND-40 CEM-I-52].freeze

$stdout.sync = true

def call(http, request, customer)
  request["X-Customer"] = customer
  request["Content-Type"] = "application/json"
  response = http.request(request)
  puts "#{Time.now.utc.strftime("%H:%M:%S")} #{request.method} #{request.path} -> #{response.code}"
rescue StandardError => e
  puts "#{Time.now.utc.strftime("%H:%M:%S")} #{request.method} #{request.path} !! #{e.class}: #{e.message}"
  sleep 1
end

THREADS.times.map do
  Thread.new do
    http = Net::HTTP.new(BASE.host, BASE.port)
    http.read_timeout = 10
    loop do
      customer = CUSTOMERS.sample
      roll = rand
      if roll < 0.15
        call(http, Net::HTTP::Get.new("/"), customer)
      elsif roll < 0.35
        call(http, Net::HTTP::Get.new("/api/materials"), customer)
      else
        order = {
          customer: customer,
          sku: SKUS.sample,
          quantity: rand(1..25),
          payment_method: rand < 0.75 ? "card" : "invoice"
        }
        post = Net::HTTP::Post.new("/api/orders")
        post.body = JSON.generate(order)
        call(http, post, customer)
      end
      sleep(THREADS / RPS * rand(0.5..1.5))
    end
  end
end.each(&:join)
