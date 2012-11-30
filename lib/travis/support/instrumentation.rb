require 'active_support/notifications'
require 'active_support/core_ext/string/inflections'
require 'securerandom' # wat
require 'core_ext/module/prepend_to'
require 'metriks'
require 'metriks/reporter/logger'

module Travis
  module Instrumentation
    class << self
      def setup
        Metriks::Reporter::Logger.new.start
      end

      def track(event, options = {})
        started_at, finished_at = options[:started_at], options[:finished_at]

        if finished_at
          Metriks.timer(event).update(finished_at - started_at)
        else
          Metriks.meter(event).mark
        end
      end
    end

    def instrument(name, options = {})
      instrument_method(name, options)
      subscribe_method(name, options)
    end

    private

      def subscribed?(event)
        ActiveSupport::Notifications.notifier.listening?(event)
      end

      def subscribe_method(name, options)
        namespace = self.name.underscore.gsub('/', '.')
        event = /^#{namespace}\.(.+\.)?#{name}(:(received|completed|failed))?$/
        ActiveSupport::Notifications.subscribe(event, &Instrumentation.method(:track)) unless subscribed?(event)
      end

      def instrument_method(name, options)
        wrapped = "#{name}_without_instrumentation"
        rename_method(name, wrapped)
        class_eval instrumentation_template(name, options[:scope], wrapped)
      end

      def rename_method(old_name, new_name)
        alias_method(new_name, old_name)
        remove_method(old_name)
        private(new_name)
      end

      def instrumentation_template(name, scope, wrapped)
        as = 'ActiveSupport::Notifications.publish "#{event}:%s", :target => self, :args => args, :started_at => started_at'
        <<-RUBY
          def #{name}(*args, &block)
            started_at = Time.now.to_f
            event = self.class.name.underscore.gsub("/", ".") #{"<< '.' << #{scope}" if scope} << ".#{name}"
            #{as % 'received'}
            result = #{wrapped}(*args, &block)
            #{as % 'completed'}, :finished_at => Time.now.to_f, :result => result
            result
          rescue Exception => e
            #{as % 'failed'}, :exception => [e.class.name, e.message]
            raise
          end
        RUBY
      end
  end
end
