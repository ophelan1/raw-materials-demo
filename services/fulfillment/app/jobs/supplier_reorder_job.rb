# Reads the silo levels the MQTT telemetry consumer stores, and places a
# purchase order for every silo below 25%.
class SupplierReorderJob < ApplicationJob
  def perform
    low = db.table_exists?(:silo_levels) ? db.select_rows("SELECT site, sku, level_pct FROM silo_levels WHERE level_pct < 25") : []
    low.each { |site, sku, level| PlacePurchaseOrderJob.perform_later(site, sku, level.to_f) }
    Rails.logger.info("Supplier reorder check: #{low.size} silos below 25%")
  end
end
