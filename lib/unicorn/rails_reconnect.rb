module Unicorn::RailsReconnect
  def reconnect
    return unless defined?(Rails)

    reconnect_txt = Rails.root.join('tmp', 'reconnect.txt')

    if reconnect_txt.exist?
      ActiveRecord::Base.clear_all_connections!
    end
  end
end
