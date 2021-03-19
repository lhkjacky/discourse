# frozen_string_literal: true

# see https://samsaffron.com/archive/2017/10/18/fastest-way-to-profile-a-method-in-ruby
class MethodProfiler
  DEBUG_SQL_QUERY_LIMIT = 500

  def self.patch(klass, methods, name, no_recurse: false)
    patches = methods.map do |method_name|

      recurse_protection = ""
      if no_recurse
        recurse_protection = <<~RUBY
          return #{method_name}__mp_unpatched(*args, &blk) if @mp_recurse_protect_#{method_name}
          @mp_recurse_protect_#{method_name} = true
        RUBY
      end

      <<~RUBY
      unless defined?(#{method_name}__mp_unpatched)
        alias_method :#{method_name}__mp_unpatched, :#{method_name}
        def #{method_name}(*args, &blk)
          unless prof = Thread.current[:_method_profiler]
            return #{method_name}__mp_unpatched(*args, &blk)
          end
          #{recurse_protection}
          begin
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            #{method_name}__mp_unpatched(*args, &blk)
          ensure
            data = (prof[:#{name}] ||= {duration: 0.0, calls: 0})
            data[:duration] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
            data[:calls] += 1
            #{"@mp_recurse_protect_#{method_name} = false" if no_recurse}
          end
        end
      end
      RUBY
    end.join("\n")

    klass.class_eval patches
  end

  def self.patch_with_debug_sql(klass, methods, name, no_recurse: false)
    patches = methods.map do |method_name|

      recurse_protection = ""
      if no_recurse
        recurse_protection = <<~RUBY
          return #{method_name}__mp_unpatched_debug_sql(*args, &blk) if @mp_recurse_protect_#{method_name}
          @mp_recurse_protect_#{method_name} = true
        RUBY
      end

      <<~RUBY
      unless defined?(#{method_name}__mp_unpatched_debug_sql)
        alias_method :#{method_name}__mp_unpatched_debug_sql, :#{method_name}
        def #{method_name}(*args, &blk)
          unless prof = Thread.current[:_method_profiler]
            return #{method_name}__mp_unpatched_debug_sql(*args, &blk)
          end
          #{recurse_protection}
          begin
            start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            #{method_name}__mp_unpatched_debug_sql(*args, &blk)
          ensure
            data = (prof[:#{name}] ||= {duration: 0.0, calls: 0, queries: []})
            duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

            if !(
              #{@@instrumentation_debug_sql_filter_transactions} &&
              (args[0] == "COMMIT" || args[0] == "BEGIN" || args[0] == "ROLLBACK")
            )
              data[:queries] << { sql: args[0], ms: duration, method: "#{method_name}" }
            end

            if data[:queries].length > #{DEBUG_SQL_QUERY_LIMIT}
              data[:queries].shift
            end

            data[:duration] += duration
            data[:calls] += 1
            #{"@mp_recurse_protect_#{method_name} = false" if no_recurse}
          end
        end
      end
      RUBY
    end.join("\n")

    klass.class_eval patches
  end

  def self.transfer
    result = Thread.current[:_method_profiler]
    Thread.current[:_method_profiler] = nil
    result
  end

  def self.start(transfer = nil)
    Thread.current[:_method_profiler] = transfer || {
      __start: Process.clock_gettime(Process::CLOCK_MONOTONIC)
    }
  end

  def self.clear
    Thread.current[:_method_profiler] = nil
  end

  def self.stop
    finish = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if data = Thread.current[:_method_profiler]
      Thread.current[:_method_profiler] = nil
      start = data.delete(:__start)
      data[:total_duration] = finish - start
    end
    data
  end

  ##
  # This is almost the same as ensure_discourse_instrumentation! but should not
  # be used in production. It stores each SQL query run, its duration, and
  # the method in an array of hashes. Only DEBUG_SQL_QUERY_LIMIT queries will
  # be preserved so the array does not get too big -- if it goes over this limit
  # we start shifting queries from the start of the array.
  #
  # filter_transactions - When true, we do not record timings of transaction
  # related commits (BEGIN, COMMIT, ROLLBACK)
  def self.debug_sql_instrumentation!(filter_transactions: false)
    Rails.logger.warn("Stop! This instrumentation is not intended for use in production outside of debugging scenarios. Please be sure you know what you are doing when enabling this instrumentation.")
    @@instrumentation_debug_sql_filter_transactions = filter_transactions
    @@instrumentation_setup_debug_sql ||= begin
      MethodProfiler.patch_with_debug_sql(PG::Connection, [
        :exec, :async_exec, :exec_prepared, :send_query_prepared, :query, :exec_params
      ], :sql)
      true
    end
  end

  def self.ensure_discourse_instrumentation!
    @@instrumentation_setup ||= begin
      MethodProfiler.patch(PG::Connection, [
        :exec, :async_exec, :exec_prepared, :send_query_prepared, :query, :exec_params
      ], :sql)

      MethodProfiler.patch(Redis::Client, [
        :call, :call_pipeline
      ], :redis)

      MethodProfiler.patch(Net::HTTP, [
        :request
      ], :net, no_recurse: true)

      MethodProfiler.patch(Excon::Connection, [
        :request
      ], :net)
      true
    end
  end

end
