# Orders web: the customer-facing ordering API for Ijzerhaven Raw Materials.
#
# A request for POST /api/orders goes:
#   user -> orders-web -> Postgres (look up material, check stock, insert order)
#        -> payments-api (charge the customer)
#        -> Postgres (mark order paid/failed, reserve stock) -> user
require "json"
require "logger"
require "net/http"
require "securerandom"
require "sequel"
require "sinatra/base"
require "appsignal"

Appsignal.load(:sinatra)
Appsignal.start

LOG = Appsignal::Logger.new("orders-web", format: Appsignal::Logger::LOGFMT)
LOG.broadcast_to(Logger.new($stdout))

DB = Sequel.connect(ENV.fetch("DATABASE_URL"), max_connections: 8)

# Raised when the payments service refuses or fails to charge an order.
class PaymentFailedError < StandardError; end

module Schema
  MATERIALS = [
    ["HRC-S235", "Hot-rolled steel coil S235", "tonne", 640_00, 4_200],
    ["AL-INGOT-99", "Aluminium ingot 99.7%", "tonne", 2_310_00, 1_150],
    ["CU-CATH-A", "Copper cathode grade A", "tonne", 8_950_00, 380],
    ["NI-BRIQ", "Nickel briquettes", "tonne", 16_400_00, 95],
    ["ZN-SHG", "Zinc SHG 99.995%", "tonne", 2_640_00, 720],
    ["PP-H350", "Polypropylene homopolymer pellets", "tonne", 1_180_00, 2_600],
    ["SI-SAND-40", "Silica sand 40/70 mesh", "tonne", 48_00, 18_000],
    ["CEM-I-52", "Portland cement CEM I 52.5R", "tonne", 115_00, 9_500]
  ].freeze

  def self.migrate!
    DB.transaction do
      DB.run("SELECT pg_advisory_xact_lock(4201)")
      DB.create_table?(:materials) do
        String :sku, primary_key: true
        String :name, null: false
        String :unit, null: false
        Integer :price_cents, null: false
        Integer :stock, null: false
      end
      DB.create_table?(:orders) do
        primary_key :id
        String :reference, null: false, unique: true
        String :customer, null: false
        String :sku, null: false
        Integer :quantity, null: false
        Integer :total_cents, null: false
        String :payment_method, null: false
        String :status, null: false, default: "pending"
        String :failure_reason
        DateTime :created_at, null: false
        DateTime :updated_at, null: false
      end
      if DB[:materials].empty?
        MATERIALS.each do |sku, name, unit, price, stock|
          DB[:materials].insert(sku: sku, name: name, unit: unit, price_cents: price, stock: stock)
        end
      end
    end
  end
end

Schema.migrate!

class PaymentsClient
  URL = URI(ENV.fetch("PAYMENTS_URL", "http://payments-api:4000"))

  def self.charge(order)
    http = Net::HTTP.new(URL.host, URL.port)
    http.open_timeout = 2
    http.read_timeout = 5
    request = Net::HTTP::Post.new("/charges", "Content-Type" => "application/json")
    request.body = JSON.generate(
      order_reference: order[:reference],
      customer: order[:customer],
      amount_cents: order[:total_cents],
      currency: "EUR",
      payment_method: order[:payment_method]
    )
    response = http.request(request)
    body =
      begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        { "error" => "bad_response", "message" => response.body.to_s[0, 200] }
      end
    [response.code.to_i, body]
  end
end

class OrdersWeb < Sinatra::Base
  set :show_exceptions, false
  set :raise_errors, false
  set :host_authorization, { permitted_hosts: [] }

  before do
    Appsignal.add_tags(
      customer: request.env["HTTP_X_CUSTOMER"],
      pod: ENV["POD_NAME"],
      node: ENV["NODE_NAME"]
    )
  end

  get "/healthz" do
    "ok"
  end

  get "/" do
    materials = DB[:materials].order(:name).all
    rows = materials.map do |m|
      "<tr><td>#{m[:sku]}</td><td>#{m[:name]}</td><td>&euro;#{format("%.2f", m[:price_cents] / 100.0)} / #{m[:unit]}</td><td>#{m[:stock]}</td></tr>"
    end
    <<~HTML
      <!doctype html><title>Ijzerhaven Raw Materials</title>
      <h1>Ijzerhaven Raw Materials &mdash; catalogue</h1>
      <p>Served by #{ENV["POD_NAME"]} on #{ENV["NODE_NAME"]}</p>
      <table border=1 cellpadding=4><tr><th>SKU</th><th>Material</th><th>Price</th><th>In stock</th></tr>#{rows.join}</table>
    HTML
  end

  get "/api/materials" do
    content_type :json
    JSON.generate(DB[:materials].order(:sku).all)
  end

  get "/api/orders/:reference" do
    content_type :json
    order = DB[:orders].where(reference: params[:reference]).first
    halt 404, JSON.generate(error: "not_found") unless order
    JSON.generate(order)
  end

  post "/api/orders" do
    content_type :json
    input = JSON.parse(request.body.read)
    quantity = Integer(input.fetch("quantity"))
    payment_method = input.fetch("payment_method", "card")

    material = DB[:materials].where(sku: input.fetch("sku")).first
    halt 422, JSON.generate(error: "unknown_sku") unless material
    if material[:stock] < quantity
      LOG.warn("Order rejected: insufficient stock", sku: material[:sku], requested: quantity, stock: material[:stock])
      halt 409, JSON.generate(error: "insufficient_stock")
    end

    now = Time.now.utc
    order = {
      reference: "ORD-#{now.strftime("%y%m%d")}-#{SecureRandom.hex(3).upcase}",
      customer: input.fetch("customer"),
      sku: material[:sku],
      quantity: quantity,
      total_cents: material[:price_cents] * quantity,
      payment_method: payment_method,
      status: "pending",
      created_at: now,
      updated_at: now
    }
    order[:id] = DB[:orders].insert(order)
    Appsignal.add_tags(order_reference: order[:reference], sku: order[:sku], payment_method: payment_method)

    status_code, payment = PaymentsClient.charge(order)

    case status_code
    when 201
      DB.transaction do
        DB[:orders].where(id: order[:id]).update(status: "paid", updated_at: Time.now.utc)
        DB[:materials].where(sku: order[:sku]).update(stock: Sequel[:stock] - quantity)
      end
      restock(order[:sku])
      Appsignal.increment_counter("orders", 1, status: "paid", payment_method: payment_method)
      Appsignal.add_distribution_value("order_value_eur", order[:total_cents] / 100.0, payment_method: payment_method)
      LOG.info("Order placed", order_reference: order[:reference], customer: order[:customer],
        sku: order[:sku], quantity: quantity, total_eur: order[:total_cents] / 100.0, payment_id: payment["payment_id"])
      status 201
      JSON.generate(order.merge(status: "paid", payment_id: payment["payment_id"]))
    when 402
      DB[:orders].where(id: order[:id]).update(status: "declined", failure_reason: payment["error"], updated_at: Time.now.utc)
      Appsignal.increment_counter("orders", 1, status: "declined", payment_method: payment_method)
      LOG.warn("Order declined by payment provider", order_reference: order[:reference],
        customer: order[:customer], reason: payment["error"])
      halt 402, JSON.generate(error: "payment_declined", reference: order[:reference])
    else
      reason = "#{payment["error"]}: #{payment["message"]}"
      DB[:orders].where(id: order[:id]).update(status: "failed", failure_reason: reason, updated_at: Time.now.utc)
      Appsignal.increment_counter("orders", 1, status: "failed", payment_method: payment_method)
      LOG.error("Order failed: payments-api could not charge the customer", order_reference: order[:reference],
        customer: order[:customer], total_eur: order[:total_cents] / 100.0,
        payments_status: status_code, payments_error: payment["error"], payment_attempt: payment["attempt_id"])
      error = PaymentFailedError.new(
        "Order #{order[:reference]} failed: payments-api returned #{status_code} (#{reason})"
      )
      Appsignal.set_error(error)
      halt 502, JSON.generate(error: "payment_failed", reference: order[:reference], detail: payment["error"])
    end
  end

  helpers do
    # Keeps the demo running forever: top up a material once it runs low.
    def restock(sku)
      restocked = DB[:materials].where(sku: sku).where { stock < 200 }.update(stock: Sequel[:stock] + 5_000)
      LOG.info("Material restocked from supplier", sku: sku, added: 5_000) if restocked.positive?
    end
  end
end
