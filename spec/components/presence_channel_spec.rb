# frozen_string_literal: true

require 'rails_helper'
require 'presence_channel'

describe PresenceChannel do
  before { PresenceChannel.clear_all! }
  after { PresenceChannel.clear_all! }

  it "can perform basic channel functionality" do
    # 10ms timeout for testing
    channel1 = PresenceChannel.new("test")
    channel2 = PresenceChannel.new("test")
    channel3 = PresenceChannel.new("test")

    expect(channel3.user_ids).to eq([])

    channel1.enter(user_id: 1, client_id: 1)
    channel2.enter(user_id: 1, client_id: 2)

    expect(channel3.user_ids).to eq([1])
    expect(channel3.count).to eq(1)

    channel1.leave(user_id: 1, client_id: 2)

    expect(channel3.user_ids).to eq([1])
    expect(channel3.count).to eq(1)

    channel2.leave(user_id: 1, client_id: 1)

    expect(channel3.user_ids).to eq([])
    expect(channel3.count).to eq(0)
  end

  it "can automatically expire users" do

    channel = PresenceChannel.new("test")

    channel.enter(user_id: 1)
    channel.enter(user_id: 1, client_id: 77)

    expect(channel.count).to eq(1)

    freeze_time Time.zone.now + 1 + PresenceChannel::DEFAULT_TIMEOUT

    expect(channel.count).to eq(0)
  end

  it "correctly sends messages to message bus" do
    channel = PresenceChannel.new("test")

    messages = MessageBus.track_publish(channel.message_bus_channel_name) do
      channel.enter(user_id: 1, client_id: "a")
    end

    expect(messages.length).to eq(1)
    expected = {
      "type" => "enter",
      "user_id" => 1,
    }
    expect(messages[0].data).to eq(expected)

    freeze_time Time.zone.now + 1 + PresenceChannel::DEFAULT_TIMEOUT

    messages = MessageBus.track_publish(channel.message_bus_channel_name) do
      channel.auto_leave
    end

    expect(messages.length).to eq(1)
    expected = {
      "type" => "leave",
      "user_id" => 1,
    }
    expect(messages[0].data).to eq(expected)
  end

  it "can track active channels, and auto_leave_all successfully" do
    channel1 = PresenceChannel.new("test1")
    channel2 = PresenceChannel.new("test2")

    channel1.enter(user_id: 1, client_id: "a")
    channel2.enter(user_id: 1, client_id: "a")

    start_time = Time.zone.now

    freeze_time start_time + PresenceChannel::DEFAULT_TIMEOUT / 2

    channel2.enter(user_id: 2, client_id: "b")

    freeze_time start_time + PresenceChannel::DEFAULT_TIMEOUT + 1

    messages = MessageBus.track_publish do
      PresenceChannel.auto_leave_all
    end

    expect(messages.map { |m| [ m.channel, m.data ] }).to contain_exactly(
      ["/presence/test1", { "type" => "leave", "user_id" => 1 }],
      ["/presence/test2", { "type" => "leave", "user_id" => 1 }]
    )

    expect(channel1.user_ids).to eq([])
    expect(channel2.user_ids).to eq([2])
  end

end
