class SupplierTimeoutError < StandardError; end

# Calls the supplier's ordering API. It's slow and times out about 1 in 8
# calls; Active Job retries twice before giving up.
class PlacePurchaseOrderJob < ApplicationJob
  queue_as :default
  retry_on SupplierTimeoutError, wait: 10.seconds, attempts: 3

  def perform(site, sku, level_pct)
    Appsignal.add_tags(site: site, sku: sku)
    Appsignal.instrument("request.supplier_api", "POST https://orders.supplier.example/v1/purchase-orders") do
      sleep rand(0.8..3.0)
      raise SupplierTimeoutError, "Supplier API timed out after 3s placing order for #{sku} (#{site})" if rand < 0.125
    end
    Rails.logger.info("Purchase order placed for #{sku} at #{site} (silo at #{level_pct.round(1)}%)")
  end
end
