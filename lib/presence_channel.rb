# frozen_string_literal: true

class PresenceChannel
  class State
    attr_reader :message_bus_last_id
    attr_reader :user_ids
    attr_reader :count

    def initialize(message_bus_last_id: , user_ids: nil, count: nil)
      raise "user_ids or count required" if user_ids.nil? && count.nil?
      @message_bus_last_id = message_bus_last_id
      @user_ids = user_ids
      @count = count || user_ids.count
    end
  end

  DEFAULT_TIMEOUT ||= 60
  GC_SECONDS ||= 24.hours.to_i

  attr_reader :name, :timeout, :message_bus_channel_name

  def initialize(name, timeout: nil)
    @name = name
    @timeout = timeout || DEFAULT_TIMEOUT
    @message_bus_channel_name = "/presence/#{name}"
  end

  def present(user_id:, client_id:)
    result = PresenceChannel.redis.eval(
      PRESENT_LUA,
      redis_keys,
      [name, user_id, client_id, (Time.zone.now + timeout).to_i]
    )

    if result == 1
      publish_message(type: "enter", user_id: user_id)
    end

    auto_leave
  end

  def leave(user_id:, client_id:)
    result = PresenceChannel.redis.eval(
      LEAVE_LUA,
      redis_keys,
      [name, user_id, client_id]
    )

    if result == 1
      publish_message(type: "leave", user_id: user_id)
    end

    auto_leave
  end

  def state(count_only: false)
    auto_leave

    if count_only
      last_id, count = PresenceChannel.redis.eval(
        COUNT_LUA,
        redis_keys,
        [Time.zone.now.to_i]
      )
    else
      last_id, ids = PresenceChannel.redis.eval(
        USER_IDS_LUA,
        redis_keys,
      )
    end
    count ||= ids&.count
    last_id = nil if last_id == -1

    if Rails.env.test? && MessageBus.backend == :memory
      # Doing it this way is not atomic, but we have no other option when
      # messagebus is not using the redis backend
      last_id = MessageBus.last_id(message_bus_channel_name)
    end

    State.new(message_bus_last_id: last_id, user_ids: ids, count: count)
  end

  def user_ids
    state.user_ids
  end

  def count
    state(count_only: true).count
  end

  def auto_leave
    left_user_ids = PresenceChannel.redis.eval(
      AUTO_LEAVE_LUA,
      redis_keys,
      [name, Time.zone.now.to_i]
    )

    left_user_ids.each do |user_id|
      publish_message(type: "leave", user_id: user_id)
    end

  end

  # Clear all members of the channel. This is intended for debugging/development only
  def clear
    PresenceChannel.redis.del(redis_key_zlist)
    PresenceChannel.redis.del(redis_key_hash)
    PresenceChannel.redis.zrem(self.class.redis_key_channel_list, name)
  end

  private

  def publish_message(type:, user_id:)
    message = {
      "type" => type,
      "user_id" => user_id,
    }

    MessageBus.publish(message_bus_channel_name, message)
  end

  # The redis key which MessageBus uses to store the 'last_id' for the channel
  # associated with this PresenceChannel.
  def message_bus_last_id_key
    return "" if Rails.env.test? && MessageBus.backend == :memory

    # TODO: Avoid using private MessageBus methods here
    encoded_channel_name = MessageBus.send(:encode_channel_name, message_bus_channel_name)
    MessageBus.reliable_pub_sub.send(:backlog_id_key, encoded_channel_name)
  end

  def redis_keys
    [redis_key_zlist, redis_key_hash, self.class.redis_key_channel_list, message_bus_last_id_key]
  end

  # The zlist is a list of client_ids, ranked by their expiration timestamp
  # we periodically delete the 'lowest ranked' items in this list based on the `timeout` of the channel
  def redis_key_zlist
    Discourse.redis.namespace_key("_presence_#{name}_zlist")
  end

  # The hash contains a map of user_id => session_count
  # when the count for a user reaches 0, the key is deleted
  # We use this hash to efficiently count the number of present users
  def redis_key_hash
    Discourse.redis.namespace_key("_presence_#{name}_hash")
  end

  # This list contains all active presence channels, ranked with the expiration timestamp of their least-recently-seen  client_id
  # We periodically check the 'lowest ranked' items in this list based on the `timeout` of the channel
  def self.redis_key_channel_list
    Discourse.redis.namespace_key("_presence_channels")
  end

  # Designed to be run periodically. Checks the channel list for channels with expired members,
  # and runs auto_leave for each eligable channel
  def self.auto_leave_all
    channels_with_expiring_members = PresenceChannel.redis.zrangebyscore(redis_key_channel_list, '-inf', Time.zone.now.to_i)
    channels_with_expiring_members.each do |name|
      new(name).auto_leave
    end
  end

  # Clear all known channels. This is intended for debugging/development only
  def self.clear_all!
    channels = PresenceChannel.redis.zrangebyscore(redis_key_channel_list, '-inf', '+inf')
    channels.each do |name|
      new(name).clear
    end
  end

  # Shortcut to access a redis client for all PresenceChannel activities.
  # PresenceChannel must use the same Redis server as MessageBus, so that
  # actions can be applied atomically. For the vast majority of Discourse
  # installations, this is the same Redis server as `Discourse.redis`.
  def self.redis
    if MessageBus.backend == :redis
      MessageBus.reliable_pub_sub.send(:pub_redis) # TODO: avoid a private API?
    elsif Rails.env.test?
      Discourse.redis.without_namespace
    else
      raise "PresenceChannel is unable to access MessageBus's Redis instance"
    end
  end

  PARAMS_LUA = <<~LUA
    local channel = ARGV[1]
    local user_id = ARGV[2]
    local client_id = ARGV[3]
    local expires = ARGV[4]

    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]
    local channels_key = KEYS[3]

    local zlist_elem = tostring(user_id) .. " " .. tostring(client_id)
  LUA

  UPDATE_GLOBAL_CHANNELS_LUA = <<~LUA
    -- Update the global channels list with the timestamp of the oldest client
    local oldest_client = redis.call('ZRANGE', zlist_key, 0, 0, 'WITHSCORES')
    if table.getn(oldest_client) > 0 then
      local oldest_client_expire_timestamp = oldest_client[2]
      redis.call('ZADD', channels_key, tonumber(oldest_client_expire_timestamp), tostring(channel))
    else
      -- The channel is now empty, delete from global list
      redis.call('ZREM', channels_key, tostring(channel))
    end
  LUA

  PRESENT_LUA = <<~LUA
    #{PARAMS_LUA}

    local added_count = redis.call('ZADD', zlist_key, expires, zlist_elem)
    if tonumber(added_count) > 0 then
      redis.call('HINCRBY', hash_key, tostring(user_id), 1)

      -- Add the channel to the global channel list. 'LT' means the value will
      -- only be set if it's lower than the existing value
      redis.call('ZADD', channels_key, "LT", expires, tostring(channel))
    end

    redis.call('EXPIREAT', hash_key, expires + #{GC_SECONDS})
    redis.call('EXPIREAT', zlist_key, expires + #{GC_SECONDS})

    return added_count
  LUA

  LEAVE_LUA = <<~LUA
    #{PARAMS_LUA}

    -- Remove the user from the channel zlist
    local removed_count = redis.call('ZREM', zlist_key, zlist_elem)

    if tonumber(removed_count) > 0 then
      #{UPDATE_GLOBAL_CHANNELS_LUA}

      -- Update the user session count in the channel hash
      local val = redis.call('HINCRBY', hash_key, user_id, -1)
      if val <= 0 then
        redis.call('HDEL', hash_key, user_id)
      end
    end

    return removed_count
  LUA

  USER_IDS_LUA = <<~LUA
    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]
    local message_bus_id_key = KEYS[4]

    local user_ids = redis.call('HKEYS', hash_key)
    table.foreach(user_ids, function(k,v) user_ids[k] = tonumber(v) end)

    local message_bus_id = tonumber(redis.call('GET', message_bus_id_key))
    if message_bus_id == nil then
      message_bus_id = -1
    end

    return { message_bus_id, user_ids }
  LUA

  COUNT_LUA = <<~LUA
    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]
    local message_bus_id_key = KEYS[4]

    local time = ARGV[1]

    local message_bus_id = tonumber(redis.call('GET', message_bus_id_key))
    if message_bus_id == nil then
      message_bus_id = -1
    end

    local count = redis.call('HLEN', hash_key)

    return { message_bus_id, count }
  LUA

  AUTO_LEAVE_LUA = <<~LUA
    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]
    local channels_key = KEYS[3]
    local channel = ARGV[1]
    local time = ARGV[2]

    local expire = redis.call('ZRANGE', zlist_key, '-inf', time, 'BYSCORE')

    local expired_user_ids = {}

    local expireOld = function(k, v)
      local user_id = v:match("[^ ]+")
      local val = redis.call('HINCRBY', hash_key, user_id, -1)
      if val <= 0 then
        table.insert(expired_user_ids, tonumber(user_id))
        redis.call('HDEL', hash_key, user_id)
      end
    end

    table.foreach(expire, expireOld)

    redis.call('ZREMRANGEBYSCORE', zlist_key, "-inf", time)

    #{UPDATE_GLOBAL_CHANNELS_LUA}

    return expired_user_ids
  LUA

end
