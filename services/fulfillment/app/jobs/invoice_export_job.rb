# The long one: exports invoices to the accounting system, 1-2.5 minutes.
# Shows up in "what is running and for how long" while it runs.
class InvoiceExportJob < ApplicationJob
  queue_as :exports

  def perform
    batches = rand(6..15)
    batches.times do |i|
      Appsignal.instrument("export_batch.accounting", "Export invoice batch") { sleep 10 }
    end
    Rails.logger.info("Invoice export finished: #{batches} batches")
  end
end
