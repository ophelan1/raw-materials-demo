# Payments API: charges orders against the acquiring bank over mutual TLS.
#
# Card payments need the client certificate from the `acquirer-mtls` secret,
# mounted at /etc/payments/tls. Every FAILURE_INTERVAL_MINUTES the scheduled
# "certificate rotation" switches to a certificate file that was never added to
# that secret, so every card charge fails until the rotation rolls back. Invoice
# (net-30) payments don't touch the acquirer and keep working.
require "json"
require "logger"
require "openssl"
require "redis"
require "securerandom"
require "sequel"
require "sinatra/base"
require "appsignal"

Appsignal.load(:sinatra)
Appsignal.start

LOG = Appsignal::Logger.new("payments", format: Appsignal::Logger::LOGFMT)
LOG.broadcast_to(Logger.new($stdout))

DB = Sequel.connect(ENV.fetch("DATABASE_URL"), max_connections: 8)

DB.transaction do
  DB.run("SELECT pg_advisory_xact_lock(4202)")
  DB.create_table?(:payment_attempts) do
    primary_key :id
    String :attempt_id, null: false, unique: true
    String :order_reference, null: false
    String :customer, null: false
    Integer :amount_cents, null: false
    String :payment_method, null: false
    String :result, null: false
    String :error
    DateTime :created_at, null: false
  end
end

REDIS = Redis.new(
  name: "ijzerhaven", role: :master,
  sentinels: ENV.fetch("REDIS_SENTINELS", "redis-sentinel:26379").split(",").map { |hp| h, p = hp.split(":"); { host: h, port: p.to_i } },
  connect_timeout: 0.5, read_timeout: 0.5, write_timeout: 0.5, reconnect_attempts: 1
)

# Raised when the mTLS session with the acquiring bank can't be set up.
class AcquirerTLSError < StandardError; end

module Acquirer
  HOST = ENV.fetch("ACQUIRER_HOST", "gw.acquirer-bank.example:8443")
  TLS_DIR = ENV.fetch("ACQUIRER_TLS_DIR", "/etc/payments/tls")
  CURRENT_CERT = File.join(TLS_DIR, "client.crt")
  ROTATED_CERT = File.join(TLS_DIR, "client-2026q4.crt")
  INTERVAL = Integer(ENV.fetch("FAILURE_INTERVAL_MINUTES", "10")) * 60
  DURATION = Integer(ENV.fetch("FAILURE_DURATION_SECONDS", "120"))

  # The broken rotation is active for the first DURATION seconds of every
  # INTERVAL, on every pod at once (it's wall-clock based).
  def self.cert_path
    (Time.now.to_i % INTERVAL) < DURATION ? ROTATED_CERT : CURRENT_CERT
  end

  def self.ssl_context
    path = cert_path
    Appsignal.instrument("load_certificate.acquirer", "Load mTLS client certificate") do
      context = OpenSSL::SSL::SSLContext.new
      context.cert = OpenSSL::X509::Certificate.new(File.read(path))
      context.key = OpenSSL::PKey.read(File.read(File.join(TLS_DIR, "client.key")))
      context
    end
  rescue Errno::ENOENT
    LOG.error(
      "Acquirer mTLS handshake aborted: client certificate not found",
      cert_path: path,
      tls_dir: TLS_DIR,
      mounted_files: Dir.children(TLS_DIR).sort.join(","),
      k8s_secret: "acquirer-mtls",
      acquirer_host: HOST,
      hint: "certificate rotation expects #{File.basename(path)} but secret acquirer-mtls does not contain it"
    )
    raise AcquirerTLSError,
      "mTLS handshake with #{HOST} failed: client certificate #{path} not found " \
      "(secret acquirer-mtls is missing #{File.basename(path)})"
  end

  def self.authorize(amount_cents)
    ssl_context
    Appsignal.instrument("request.acquirer", "POST https://#{HOST}/v2/authorizations") do
      sleep(rand(0.06..0.22))
    end
    # A small, steady share of genuine bank declines.
    rand < 0.015 ? %w[insufficient_funds card_expired do_not_honor].sample : nil
  end
end

class PaymentsAPI < Sinatra::Base
  set :show_exceptions, false
  set :raise_errors, false
  set :host_authorization, { permitted_hosts: [] }

  before do
    Appsignal.add_tags(pod: ENV["POD_NAME"], node: ENV["NODE_NAME"])
  end

  get "/healthz" do
    "ok"
  end

  post "/charges" do
    content_type :json
    input = JSON.parse(request.body.read)
    attempt = {
      attempt_id: "pa_#{SecureRandom.hex(6)}",
      order_reference: input.fetch("order_reference"),
      customer: input.fetch("customer"),
      amount_cents: Integer(input.fetch("amount_cents")),
      payment_method: input.fetch("payment_method"),
      created_at: Time.now.utc
    }
    Appsignal.add_tags(order_reference: attempt[:order_reference], payment_method: attempt[:payment_method],
      customer: attempt[:customer])

    # Idempotency: a retried charge for the same order must not hit the bank
    # twice. Redis being down doesn't block payments; it only loses this guard.
    begin
      unless REDIS.set("charge:#{attempt[:order_reference]}", attempt[:attempt_id], nx: true, ex: 3600)
        Appsignal.increment_counter("payment_duplicates_blocked", 1)
        halt 409, JSON.generate(error: "duplicate_charge", order_reference: attempt[:order_reference])
      end
    rescue Redis::BaseError => e
      LOG.warn("Idempotency check skipped: Redis unavailable", error: e.class.name, message: e.message)
    end

    begin
      decline =
        if attempt[:payment_method] == "invoice"
          open_invoices = DB[:payment_attempts]
            .where(customer: attempt[:customer], payment_method: "invoice", result: "authorized").count
          LOG.info("Invoice payment approved on credit terms", customer: attempt[:customer], open_invoices: open_invoices)
          nil
        else
          Acquirer.authorize(attempt[:amount_cents])
        end
    rescue AcquirerTLSError => e
      DB[:payment_attempts].insert(attempt.merge(result: "error", error: e.message))
      Appsignal.increment_counter("payment_attempts", 1, result: "error", payment_method: attempt[:payment_method])
      Appsignal.set_error(e)
      halt 502, JSON.generate(error: "acquirer_tls_error", message: e.message, attempt_id: attempt[:attempt_id])
    end

    if decline
      DB[:payment_attempts].insert(attempt.merge(result: "declined", error: decline))
      Appsignal.increment_counter("payment_attempts", 1, result: "declined", payment_method: attempt[:payment_method])
      LOG.warn("Card payment declined by acquirer", order_reference: attempt[:order_reference], reason: decline)
      halt 402, JSON.generate(error: decline, attempt_id: attempt[:attempt_id])
    end

    DB[:payment_attempts].insert(attempt.merge(result: "authorized"))
    Appsignal.increment_counter("payment_attempts", 1, result: "authorized", payment_method: attempt[:payment_method])
    LOG.info("Payment authorized", order_reference: attempt[:order_reference],
      amount_eur: attempt[:amount_cents] / 100.0, payment_method: attempt[:payment_method])
    status 201
    JSON.generate(payment_id: attempt[:attempt_id], status: "authorized")
  end
end
