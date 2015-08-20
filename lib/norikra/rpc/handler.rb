require 'norikra/error'
require 'norikra/logger'
include Norikra::Log

require 'norikra/rpc'

require 'norikra/query'

class Norikra::RPC::Handler
  def initialize(engine)
    @engine = engine
    @shut_off_mode = false
  end

  def shut_off(mode)
    @shut_off_mode = true
  end

  def logging(type, handler, args=[])
    if type == :manage
      debug("RPC"){ { handler: handler.to_s, args: args } }
    else
      trace("RPC"){ { handler: handler.to_s, args: args } }
    end

    begin
      yield
    rescue Norikra::ClientError => e
      info "ClientError #{e.class}: #{e.message}"
      raise Norikra::RPC::ClientError, e.message
    rescue => e
      error "Exception #{e.class}: #{e.message}"
      e.backtrace.each do |t|
        error "  " + t
      end
      raise Norikra::RPC::ServerError, "#{e.class}, #{e.message}"
    end
  end

  def targets
    logging(:show, :targets){
      @engine.targets.map(&:to_hash)
    }
  end

  def open(target, fields, auto_field)
    logging(:manage, :open, [target, fields]){
      r = @engine.open(target, fields, auto_field)
      !!r
    }
  end

  def close(target)
    logging(:manage, :close, [target]){
      r = @engine.close(target)
      !!r
    }
  end

  def modify(target, auto_field)
    logging(:manage, :modify, [target, auto_field]){
      r = @engine.modify(target, auto_field)
      !!r
    }
  end

  def queries
    logging(:show, :queries){
      @engine.queries.map(&:to_hash) + @engine.suspended_queries.map(&:to_hash)
    }
  end

  def register(query_name, query_group, expression)
    logging(:manage, :register, [query_name, query_group, expression]){
      r = @engine.register(Norikra::Query.new(name: query_name, group: query_group, expression: expression))
      !!r
    }
  end

  def deregister(query_name)
    logging(:manage, :deregister, [query_name]){
      r = @engine.deregister(query_name)
      !!r
    }
  end

  def replace(query_name, query_group, expression)
    logging(:manage, :replace, [query_name, query_group, expression]){
      r = @engine.replace(Norikra::Query.new(name: query_name, group: query_group, expression: expression))
      !!r
    }
  end

  def suspend(query_name)
    logging(:manage, :suspend, [query_name]){
      r = @engine.suspend(query_name)
      !!r
    }
  end

  def resume(query_name)
    logging(:manage, :suspend, [query_name]){
      r = @engine.resume(query_name)
      !!r
    }
  end

  def fields(target)
    logging(:show, :fields, [target]){
      @engine.typedef_manager.field_list(target)
    }
  end

  def reserve(target, fieldname, type)
    logging(:manage, :reserve, [target, fieldname, type]){
      r = @engine.reserve(target, fieldname, type)
      !!r
    }
  end

  def send(target, events)
    raise Norikra::RPC::ServiceUnavailableError if @shut_off_mode

    logging(:data, :send, [target, events]){
      r = @engine.send(target, events)
      !!r
    }
  end

  def event(query_name)
    logging(:show, :event, [query_name]){
      @engine.output_pool.pop(query_name)
    }
  end

  def see(query_name)
    logging(:show, :see, [query_name]){
      @engine.output_pool.fetch(query_name)
    }
  end

  def sweep(query_group=nil)
    logging(:show, :sweep){
      @engine.output_pool.sweep(query_group)
    }
  end

  def logs
    logging(:show, :logs){
      Norikra::Log.logger.buffer
    }
  end

  # post('/listen') # get all events as stream, during connection keepaliving
end
