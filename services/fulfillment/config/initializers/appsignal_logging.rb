# Send the Rails log, including Active Job's "Enqueued ... (Job ID: ...)" and
# "Performed ... in N ms" lines, to AppSignal Logging as well as stdout.
Rails.application.config.after_initialize do
  Rails.logger.broadcast_to(Appsignal::Logger.new("fulfillment"))
end
