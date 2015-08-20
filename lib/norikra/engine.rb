require 'java'

require 'norikra/error'
require 'norikra/target'
require 'norikra/listener'

require 'norikra/query'
require 'norikra/suspended_query'

require 'norikra/logger'
include Norikra::Log

require 'esper-5.2.0.jar'
require 'esper/lib/commons-logging-1.1.3.jar'
require 'esper/lib/antlr-runtime-4.1.jar'
require 'esper/lib/cglib-nodep-3.1.jar'

require 'norikra/typedef_manager'

module Norikra
  class Engine
    attr_reader :targets, :queries, :suspended_queries, :output_pool, :typedef_manager

    def initialize(output_pool, typedef_manager, opts={})
      @statistics = {
        started: Time.now,
        events: { input: 0, processed: 0, output: 0, },
      }

      @output_pool = output_pool
      @typedef_manager = typedef_manager

      conf = configuration(opts)
      @service = com.espertech.esper.client.EPServiceProviderManager.getDefaultProvider(conf)
      @config = @service.getEPAdministrator.getConfiguration

      @mutex = Mutex.new

      # fieldsets already registered into @runtime
      @registered_fieldsets = {} # {target => {fieldset_summary => Fieldset}

      @targets = []
      @queries = []
      @suspended_queries = []

      @waiting_queries = []

      @listeners = {} # Listener.label => Listener
      @running_listeners = {} # query_name => listener
    end

    def statistics
      s = @statistics
      {
        started: s[:started].rfc2822,
        uptime: self.uptime,
        memory: self.memory_statistics,
        garbage_collector: self.gc_statistics,
        input_events: s[:events][:input],
        processed_events: s[:events][:processed],
        output_events: s[:events][:output],
        queries: @queries.size,
        targets: @targets.size,
      }
    end

    def uptime
      # up 239 days, 20:40
      seconds = (Time.now - @statistics[:started]).to_i
      days = seconds / (24*60*60)
      hours = (seconds - days * (24*60*60)) / (60*60)
      minutes = (seconds - days * (24*60*60) - hours * (60*60)) / 60
      "#{days} days, #{sprintf("%02d", hours)}:#{sprintf("%02d", minutes)}"
    end

    def memory_statistics
      mb = 1024 * 1024

      memoryBean = Java::JavaLangManagement::ManagementFactory.getMemoryMXBean()

      usage = memoryBean.getHeapMemoryUsage()
      total = usage.getMax() / mb
      committed = usage.getCommitted() / mb
      committed_percent = (committed.to_f / total * 1000).floor / 10.0
      used = usage.getUsed() / mb
      used_percent = (used.to_f / total * 1000).floor / 10.0
      heap = { max: total, committed: committed, committed_percent: committed_percent, used: used, used_percent: used_percent }

      usage = memoryBean.getNonHeapMemoryUsage()
      total = usage.getMax() / mb
      committed = usage.getCommitted() / mb
      committed_percent = (committed.to_f / total * 1000).floor / 10.0
      used = usage.getUsed() / mb
      used_percent = (used.to_f / total * 1000).floor / 10.0
      non_heap = { max: total, committed: committed, committed_percent: committed_percent, used: used, used_percent: used_percent }

      { heap: heap, nonheap: non_heap }
    end

    def gc_statistics
      gcBeans = Java::JavaLangManagement::ManagementFactory.getGarbageCollectorMXBeans()

      gc = {}
      gcBeans.each do |bean|
        name = bean.getName()
        gc[name] = {
          total_count: bean.getCollectionCount(),
          total_time: bean.getCollectionTime(),
        }
      end

      gc
    end

    def camelize(sym)
      sym.to_s.split(/_/).map(&:capitalize).join
    end

    def configuration(opts)
      conf = com.espertech.esper.client.Configuration.new
      defaults = conf.getEngineDefaults

      if opts[:thread]
        t = opts[:thread]
        threading = defaults.getThreading
        [:inbound, :outbound, :route_exec, :timer_exec].each do |sym|
          next unless t[sym] && t[sym][:threads] && t[sym][:threads] > 0

          threads = t[sym][:threads].to_i
          capacity = t[sym][:capacity].to_i
          info "Engine #{sym} thread pool enabling", threads: threads, capacity: (capacity == 0 ? 'default' : capacity)

          cam = camelize(sym)
          threading.send("setThreadPool#{cam}".to_sym, true)
          threading.send("setThreadPool#{cam}NumThreads".to_sym, threads)
          if t[sym][:capacity] && t[sym][:capacity] > 0
            threading.send("setThreadPool#{cam}Capacity".to_sym, capacity)
          end
        end
      end

      conf
    end

    def start
      debug "norikra engine starting: creating esper runtime"
      @runtime = @service.getEPRuntime
      debug "norikra engine started"
    end

    def stop
      debug "stopping norikra engine: stop all statements on esper"
      @service.getEPAdministrator.stopAllStatements
      debug "norikra engine stopped"
    end

    def open(target_name, fields=nil, auto_field=true)
      # fields nil || [] => lazy
      # fields {'fieldname' => 'type'} : type 'string', 'boolean', 'int', 'long', 'float', 'double'
      info "opening target", target: target_name, fields: fields, auto_field: auto_field
      raise Norikra::ArgumentError, "invalid target name" unless Norikra::Target.valid?(target_name)
      target = Norikra::Target.new(target_name, fields, auto_field)
      return false if @targets.include?(target)
      open_target(target)
    end

    def close(target_name)
      info "closing target", target: target_name
      targets = @targets.select{|t| t.name == target_name}
      return false if targets.size != 1
      target = targets.first
      @queries.select{|q| q.targets.include?(target.name)}.each do |query|
        deregister_query(query)
      end
      close_target(target)
    end

    def modify(target_name, auto_field)
      info "modify target", target: target_name, auto_field: auto_field
      targets = @targets.select{|t| t.name == target_name}
      if targets.size != 1
        raise Norikra::ArgumentError, "target name '#{target_name}' not found"
      end
      target = targets.first
      target.auto_field = auto_field
    end

    def reserve(target_name, field, type)
      @typedef_manager.reserve(target_name, field, type)
    end

    def register(query)
      info "registering query", name: query.name, targets: query.targets, expression: query.expression
      raise Norikra::ClientError, "query name '#{query.name}' already exists" if @queries.select{|q| q.name == query.name }.size > 0
      raise Norikra::ClientError, "query name '#{query.name}' already exists in suspended" if @suspended_queries.select{|q| q.name == query.name }.size > 0
      if reason = query.invalid?
        raise Norikra::ClientError, "invalid query '#{query.name}': #{reason}"
      end

      query.targets.each do |target_name|
        open(target_name) unless @targets.any?{|t| t.name == target_name}
      end
      register_query(query)
    end

    def deregister(query_name)
      info "de-registering query", name: query_name
      queries = @queries.select{|q| q.name == query_name }
      s_queries = @suspended_queries.select{|q| q.name == query_name }

      if queries.size == 1
        deregister_query(queries.first)
      elsif s_queries.size == 1
        @suspended_queries.delete(s_queries.first)
        true
      else
        nil # just ignore for 'not found'
      end
    end

    def replace(query)
      info "replacing query", name: query.name, targets: query.targets, expression: query.expression
      if @queries.select{|q| q.name == query.name }.size == 0 &&
         @suspended_queries.select{|q| q.name == query.name }.size == 0
        raise Norikra::ClientError, "query name '#{query.name}' does not exists"
      end

      if reason = query.invalid?
        raise Norikra::ClientError, "invalid query '#{query.name}': #{reason}"
      end

      deregister(query.name)
      register(query)
    end

    def suspend(query_name)
      info "suspending query", name: query_name
      queries = @queries.select{|q| q.name == query_name }
      return nil unless queries.size == 1 # just ignore for 'not found'

      suspending_query = queries.first
      suspended_query = Norikra::SuspendedQuery.new(suspending_query)

      deregister_query(suspending_query)
      add_suspended_query(suspended_query)
    end

    def resume(query_name)
      info "resuming query", name: query_name
      queries = @suspended_queries.select{|q| q.name == query_name }
      return nil unless queries.size == 1 # just ignore

      suspended_query = queries.first
      query = suspended_query.create # suspended query -> query object

      query.targets.each do |target_name|
        open(target_name) unless @targets.any?{|t| t.name == target_name}
      end
      register_query(query)
      remove_suspended_query(suspended_query)
    end

    def event_filter(event)
      unless event.is_a?(Hash)
        error "Invalid input event: Non-Hash (JSON) object: #{event.class}"
        return nil
      end
      event.keys.each do |k|
        if ! k.is_a?(String)
          warn "Invalid key in event: Non-String field key: #{k.class}"
          event.delete(k)
        elsif k =~ /^\d/
          warn "Invalid key in event: Starting with numeric char: #{k.to_s}"
          event.delete(k)
        end
      end
      event
    end

    def send(target_name, events)
      trace "send messages", target: target_name, events: events

      @statistics[:events][:input] += events.size

      unless @targets.any?{|t| t.name == target_name} # discard events for target not registered
        trace "messages skipped for non-opened target", target: target_name
        return
      end
      return if events.size < 1

      target = @targets.select{|t| t.name == target_name}.first

      if @typedef_manager.lazy?(target.name)
        info "opening lazy target", target: target

        first_event = event_filter(events.first)
        if first_event.nil? # non-hash object
          raise Norikra::ClientError, "Input data must be JSON object"
        end
        debug "generating base fieldset from event", target: target.name, event: first_event
        base_fieldset = @typedef_manager.generate_base_fieldset(target.name, first_event)

        debug "registering base fieldset", target: target.name, base: base_fieldset
        register_base_fieldset(target.name, base_fieldset)

        info "target successfully opened with fieldset", target: target, base: base_fieldset
      end

      registered_data_fieldset = @registered_fieldsets[target_name][:data]

      strict_refer = (not target.auto_field?)

      events.each do |input_event|
        event = event_filter(input_event)
        next if event.nil? # non-hash object

        fieldset = @typedef_manager.refer(target_name, event, strict_refer)

        unless registered_data_fieldset[fieldset.summary]
          # register waiting queries including this fieldset, and this fieldset itself
          debug "registering unknown fieldset", target: target_name, fieldset: fieldset
          register_fieldset(target_name, fieldset)
          debug "successfully registered"

          # fieldset should be refined, when waiting_queries rewrite inheritance structure and data fieldset be renewed.
          fieldset = @typedef_manager.refer(target_name, event, strict_refer)
          debug "re-referred data fieldset", target: target_name, fieldset: fieldset
        end

        trace "calling sendEvent with bound fieldset (w/ valid event_type_name)", target: target_name, event: event
        trace("This is assert for valid event_type_name"){ { event_type_name: fieldset.event_type_name } }
        formed = fieldset.format(event)
        trace "sendEvent", data: formed
        @runtime.sendEvent(formed.to_java, fieldset.event_type_name)
      end
      target.update!
      @statistics[:events][:processed] += events.size
      nil
    end

    def load(type, plugin_klass)
      case type
      when :udf then load_udf(plugin_klass)
      when :listener then load_listener(plugin_klass)
      else
        raise "BUG: unknown plugin type: #{type}"
      end
    end

    private

    def open_target(target)
      @mutex.synchronize do
        return false if @targets.include?(target)

        @typedef_manager.add_target(target.name, target.fields)
        @registered_fieldsets[target.name] = {base: {}, query: {}, data: {}}

        unless @typedef_manager.lazy?(target.name)
          base_fieldset = @typedef_manager.base_fieldset(target.name)

          @typedef_manager.bind_fieldset(target.name, :base, base_fieldset)
          register_fieldset_actually(target.name, base_fieldset, :base)
        end

        @targets.push(target)
      end
      true
    end

    def close_target(target)
      @mutex.synchronize do
        return false unless @targets.include?(target)

        @typedef_manager.remove_target(target.name)
        @registered_fieldsets.delete(target.name)

        @targets.delete(target)
      end
      true
    end

    def register_base_fieldset(target_name, fieldset)
      # for lazy target, with generated fieldset from sent events.first
      @mutex.synchronize do
        return false unless @typedef_manager.lazy?(target_name)

        @typedef_manager.activate(target_name, fieldset)
        register_fieldset_actually(target_name, fieldset, :base)
      end
      true
    end

    def update_inherits_graph(target_name, query_fieldset)
      # replace registered data fieldsets with new fieldset inherits this query fieldset
      @typedef_manager.supersets(target_name, query_fieldset).each do |set|
        rebound = set.rebind(true, query_fieldset) # update event_type_name with new inheritations & nullable fields

        register_fieldset_actually(target_name, rebound, :data, true) # replacing on esper engine
        @typedef_manager.replace_fieldset(target_name, set, rebound)
        deregister_fieldset_actually(target_name, set.event_type_name, :data)
      end
    end

    def register_query(query)

      if lo_target_name = Norikra::Listener::Loopback.target(query.group)
        raise "Invalid loopback target name should be checked before. THIS IS BUG." unless Norikra::Target.valid?(lo_target_name)

        target = Norikra::Target.new(lo_target_name)
        unless @targets.include?(target)
          info "opening loopback target", target: lo_target_name
          open_target(target)
        end
      end

      @mutex.synchronize do
        raise Norikra::ClientError, "query '#{query.name}' already exists" unless @queries.select{|q| q.name == query.name }.empty?
        if reason = query.invalid?
          raise Norikra::ClientError, "invalid query '#{query.name}': #{reason}"
        end
        if lo_target_name = Norikra::Listener::Loopback.target(query.group)
          raise Norikra::ClientError, "loopback target '#{lo_target_name}'" unless Norikra::Target.valid?(lo_target_name)
        end

        unless @typedef_manager.ready?(query)
          @waiting_queries.push(query)
          trace("waiting query fields"){ { targets: query.targets, fields: query.targets.map{|t| query.fields(t)} } }
          @typedef_manager.register_waiting_fields(query)
          @queries.push(query)
          return
        end

        mapping = @typedef_manager.generate_fieldset_mapping(query)
        mapping.each do |target_name, query_fieldset|
          trace "binding query fieldset", fieldset: query_fieldset
          @typedef_manager.bind_fieldset(target_name, :query, query_fieldset)
          trace "registering query fieldset", fieldset: query_fieldset
          register_fieldset_actually(target_name, query_fieldset, :query)
          update_inherits_graph(target_name, query_fieldset)
          query.fieldsets[target_name] = query_fieldset
        end

        register_query_actually(query, mapping)
        @queries.push(query)
      end
      true
    end

    def deregister_query(query)
      @mutex.synchronize do
        return nil unless @queries.include?(query)

        deregister_query_actually(query)
        @queries.delete(query)

        if @waiting_queries.include?(query)
          @waiting_queries.delete(query)
        else
          query.fieldsets.each do |target_name, query_fieldset|
            removed_event_type_name = query_fieldset.event_type_name

            @typedef_manager.unbind_fieldset(target_name, :query, query_fieldset)
            update_inherits_graph(target_name, query_fieldset)
            deregister_fieldset_actually(target_name, removed_event_type_name, :query)
          end
        end
      end
      true
    end

    def add_suspended_query(query)
      @mutex.synchronize do
        return nil if @suspended_queries.include?(query)
        @suspended_queries << query
      end
      true
    end

    def remove_suspended_query(query)
      @mutex.synchronize do
        @suspended_queries.delete(query)
      end
      true
    end

    def register_waiting_queries
      ready = []
      not_ready = []
      @waiting_queries.each do |q|
        if @typedef_manager.ready?(q)
          ready.push(q)
        else
          not_ready.push(q)
        end
      end
      @waiting_queries = not_ready

      ready.each do |query|
        mapping = @typedef_manager.generate_fieldset_mapping(query)
        mapping.each do |target_name, query_fieldset|
          trace "binding query fieldset for waiting query", query: query, target: target_name, fieldset: query_fieldset
          @typedef_manager.bind_fieldset(target_name, :query, query_fieldset)
          trace "registering query fieldset", target: target_name, fieldset: query_fieldset
          register_fieldset_actually(target_name, query_fieldset, :query)
          update_inherits_graph(target_name, query_fieldset)
          query.fieldsets[target_name] = query_fieldset
        end
        register_query_actually(query, mapping)
      end
    end

    def register_fieldset(target_name, fieldset)
      @mutex.synchronize do
        trace "binding data fieldset", fieldset: fieldset # to prepare pickup waiting queries by newly comming fields
        @typedef_manager.bind_fieldset(target_name, :data, fieldset)

        if @waiting_queries.size > 0
          register_waiting_queries
        end

        diff_nullable_fields = []

        @typedef_manager.subsets(target_name, fieldset).each do |query_fieldset|
          next unless query_fieldset.level == :query
          # fill nullable fields of all required query fieldsets
          diff_nullable_fields += fieldset.nullable_diff(query_fieldset)
        end

        unless diff_nullable_fields.empty?
          trace "query fieldset has nullable diff", diff: diff_nullable_fields
          fieldset.update(diff_nullable_fields, true) # nullable fields are always optional
          trace "rebinding data fieldset w/ nullable fields", fieldset: fieldset
          rebound = fieldset.rebind(false) # type_name is not required to be updated because it is not registered yet
          @typedef_manager.replace_fieldset(target_name, fieldset, rebound)
          fieldset = rebound
        end
        debug "registering data fieldset", target: target_name, fieldset: fieldset
        register_fieldset_actually(target_name, fieldset, :data)
      end
    end

    def load_udf(udf_klass)
      udf_klass.init if udf_klass.respond_to?(:init)

      udf = udf_klass.new
      if udf.is_a? Norikra::UDF::SingleRow
        load_udf_actually(udf)
      elsif udf.is_a? Norikra::UDF::AggregationSingle
        load_udf_aggregation_actually(udf)
      end
    end

    def load_listener(klass)
      @listeners[klass.label] = klass
      klass
    end

    def create_listener(query)
      opts = Norikra::Listener.parse(query.group)
      klass = if opts && @listeners.has_key?(opts[:name])
                @listeners[opts[:name]]
              else
                Norikra::Listener::MemoryPool
              end
      argument = opts ? opts[:argument] : nil
      trace("selecting listeners"){ { group: query.group, listener: klass, argument: argument } }

      inst = klass.new(argument, query.name, query.group)
      inst.events_statistics = @statistics[:events]

      inst.engine = self if inst.respond_to?(:engine=)
      inst.output_pool = @output_pool if inst.respond_to?(:output_pool=)

      inst.start
      inst
    end

    # this method should be protected with @mutex lock
    def register_query_actually(query, mapping)
      # 'mapping' argument is {target => fieldset}
      event_type_name_map = {}
      mapping.keys.each do |key|
        event_type_name_map[key] = mapping[key].event_type_name
      end

      administrator = @service.getEPAdministrator

      statement_model = administrator.compileEPL(query.expression)
      trace("rewriting query"){ { source: statement_model.toEPL, event_type_name_map: event_type_name_map } }
      Norikra::Query.rewrite_query(statement_model, event_type_name_map)
      trace("query rewrite result"){ { result: statement_model.toEPL } }

      @running_listeners[query.name] = listener = create_listener(query)

      epl = administrator.create(statement_model)
      epl.java_send :addListener, [com.espertech.esper.client.UpdateListener.java_class], listener

      query.statement_name = epl.getName

      # epl is automatically started.
      # epl.isStarted #=> true
      true
    end

    # this method should be protected with @mutex lock
    def deregister_query_actually(query)
      administrator = @service.getEPAdministrator
      epl = administrator.getStatement(query.statement_name)
      return unless epl

      epl.stop unless epl.isStopped
      epl.destroy unless epl.isDestroyed
      listener = @running_listeners.delete(query.name)
      listener.shutdown
      @output_pool.remove(query.name, query.group)
    end

    # this method should be protected with @mutex lock
    def register_fieldset_actually(target_name, fieldset, level, replace=false)
      return if level == :data && @registered_fieldsets[target_name][level][fieldset.summary] && !replace

      # Map Supertype (target) and Subtype (typedef name, like TARGET_TypeDefName)
      # http://esper.codehaus.org/esper-4.9.0/doc/reference/en-US/html/event_representation.html#eventrep-map-supertype
      # epService.getEPAdministrator().getConfiguration()
      #   .addEventType("AccountUpdate", accountUpdateDef, new String[] {"BaseUpdate"});
      case level
      when :base
        debug("add event type"){ { target: target_name, level: 'base', event_type: fieldset.event_type_name } }
        @config.addEventType(fieldset.event_type_name, fieldset.definition)
      when :query
        base_name = @typedef_manager.base_fieldset(target_name).event_type_name
        debug("add event type"){ { target: target_name, level: 'query', event_type: fieldset.event_type_name, base: base_name } }
        @config.addEventType(fieldset.event_type_name, fieldset.definition, [base_name].to_java(:string))
      else # :data
        subset_names = @typedef_manager.subsets(target_name, fieldset).map(&:event_type_name)
        debug("add event type"){ { target: target_name, level: 'data', event_type: fieldset.event_type_name, inherit: subset_names } }
        @config.addEventType(fieldset.event_type_name, fieldset.definition, subset_names.to_java(:string))

        @registered_fieldsets[target_name][level][fieldset.summary] = fieldset
      end
      nil
    end

    # this method should be protected with @mutex lock as same as register
    def deregister_fieldset_actually(target_name, event_type_name, level)
      return if level == :base

      # DON'T check @registered_fieldsets[target_name][level][fieldset.summary]
      # removed fieldset should be already replaced with register_fieldset_actually w/ replace flag
      debug "remove event type", target: target_name, event_type: event_type_name
      @config.removeEventType(event_type_name, true)
    end

    VALUE_CACHE_ENUM = com.espertech.esper.client.ConfigurationPlugInSingleRowFunction::ValueCache
    FILTER_OPTIMIZABLE_ENUM = com.espertech.esper.client.ConfigurationPlugInSingleRowFunction::FilterOptimizable

    def load_udf_actually(udf)
      debug "importing class into config object", name: udf.class.to_s

      functionName, className, methodName = udf.definition

      valueCache = udf.value_cache ? VALUE_CACHE_ENUM::ENABLED : VALUE_CACHE_ENUM::DISABLED
      filterOptimizable = udf.filter_optimizable ? FILTER_OPTIMIZABLE_ENUM::ENABLED : FILTER_OPTIMIZABLE_ENUM::DISABLED
      rethrowExceptions = udf.rethrow_exceptions

      debug "adding SingleRowFunction", function: functionName, javaClass: className, javaMethod: methodName
      @config.addPlugInSingleRowFunction(functionName, className, methodName, valueCache, filterOptimizable, rethrowExceptions)
      functionName
    end

    def load_udf_aggregation_actually(udf)
      debug "importing class into config object", name: udf.class.to_s

      functionName, factoryClassName = udf.definition

      debug "adding AggregationSingleFactory", function: functionName, javaClass: factoryClassName
      @config.addPlugInAggregationFunctionFactory(functionName, factoryClassName)
      functionName
    end
  end
end
