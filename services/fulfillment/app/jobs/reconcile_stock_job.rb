# Compares paid orders against stock movements and flags materials that need
# a supplier delivery soon.
class ReconcileStockJob < ApplicationJob
  def perform
    low = db.select_rows(<<~SQL)
      SELECT m.sku, m.stock, coalesce(sum(o.quantity) FILTER (WHERE o.created_at > now() - interval '1 hour'), 0)
      FROM materials m LEFT JOIN orders o ON o.sku = m.sku AND o.status = 'paid'
      GROUP BY m.sku, m.stock
    SQL
    sleep rand(0.3..1.5) # reconciliation work
    at_risk = low.select { |_, stock, hourly| hourly.to_i.positive? && stock.to_i < hourly.to_i * 24 }
    Rails.logger.info("Stock reconciled: #{low.size} materials, #{at_risk.size} below 24h of demand")
    Appsignal.set_gauge("fulfillment_materials_at_risk", at_risk.size)
  end
end
