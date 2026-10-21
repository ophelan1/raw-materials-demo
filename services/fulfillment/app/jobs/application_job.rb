class ApplicationJob < ActiveJob::Base
  # Read-only views onto the orders app's tables.
  def db = ActiveRecord::Base.connection
end
