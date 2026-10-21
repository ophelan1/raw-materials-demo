# Plans truck slots for the next hour's paid orders. Runtime varies a lot with
# the number of orders, which makes it a good one for duration tracking.
module Dispatch
  class TruckScheduleJob < ApplicationJob
    queue_as :critical

    def perform
      orders = db.select_value("SELECT count(*) FROM orders WHERE status = 'paid' AND created_at > now() - interval '15 minutes'").to_i
      sleep(0.5 + orders * rand(0.05..0.2))
      Rails.logger.info("Truck schedule planned: #{orders} orders, #{(orders / 6.0).ceil} trucks")
    end
  end
end
