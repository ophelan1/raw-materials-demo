require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"

Bundler.require(*Rails.groups)

module Fulfillment
  # Fulfillment worker: no web server, only Solid Queue running Active Job
  # jobs for the warehouse (stock reconciliation, supplier reorders, truck
  # scheduling, invoice exports). AppSignal instruments every job through its
  # Active Job / Solid Queue integration.
  class Application < Rails::Application
    config.load_defaults 8.0
    config.eager_load = true
    config.root = File.expand_path("..", __dir__)
    config.active_job.queue_adapter = :solid_queue
    config.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
    config.log_level = :info
  end
end
