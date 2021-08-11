# frozen_string_literal: true

class PresenceChannel

  DEFAULT_TIMEOUT ||= 60

  attr_reader :name, :timeout, :message_bus_channel_name

  def initialize(name, timeout: nil)
    @name = name
    @timeout = timeout || DEFAULT_TIMEOUT
    @message_bus_channel_name = "/presence/#{name}"
  end

  def present(user_id:, client_id:)
    result = Discourse.redis.eval(
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
    result = Discourse.redis.eval(
      LEAVE_LUA,
      redis_keys,
      [name, user_id, client_id]
    )

    if result == 1
      publish_message(type: "leave", user_id: user_id)
    end

    auto_leave
  end

  def user_ids
    auto_leave

    Discourse.redis.eval(
      USER_IDS_LUA,
      redis_keys,
    )
  end

  def count
    auto_leave

    Discourse.redis.eval(
      COUNT_LUA,
      redis_keys,
      [Time.zone.now.to_i]
    )
  end

  def auto_leave
    left_user_ids = Discourse.redis.eval(
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
    Discourse.redis.without_namespace.del(redis_key_zlist)
    Discourse.redis.without_namespace.del(redis_key_hash)
    Discourse.redis.without_namespace.zrem(self.class.redis_key_channel_list, name)
  end

  private

  def publish_message(type:, user_id:)
    message = {
      "type" => type,
      "user_id" => user_id,
    }

    MessageBus.publish(message_bus_channel_name, message)
  end

  def redis_keys
    [redis_key_zlist, redis_key_hash, self.class.redis_key_channel_list]
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
    channels_with_expiring_members = Discourse.redis.zrangebyscore("_presence_channels", '-inf', Time.zone.now.to_i)
    channels_with_expiring_members.each do |name|
      new(name).auto_leave
    end
  end

  # Clear all known channels. This is intended for debugging/development only
  def self.clear_all!
    channels = Discourse.redis.without_namespace.zrangebyscore(redis_key_channel_list, '-inf', '+inf')
    channels.each do |name|
      new(name).clear
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

    local user_ids = redis.call('HKEYS', hash_key)
    table.foreach(user_ids, function(k,v) user_ids[k] = tonumber(v) end)

    return user_ids
  LUA

  COUNT_LUA = <<~LUA
    local zlist_key = KEYS[1]
    local hash_key = KEYS[2]

    local time = ARGV[1]

    return redis.call('HLEN', hash_key)
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
