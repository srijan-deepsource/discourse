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

    channel1.present(user_id: 1, client_id: 1)
    channel2.present(user_id: 1, client_id: 2)

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

    channel.present(user_id: 1, client_id: 76)
    channel.present(user_id: 1, client_id: 77)

    expect(channel.count).to eq(1)

    freeze_time Time.zone.now + 1 + PresenceChannel::DEFAULT_TIMEOUT

    expect(channel.count).to eq(0)
  end

  it "correctly sends messages to message bus" do
    channel = PresenceChannel.new("test")

    messages = MessageBus.track_publish(channel.message_bus_channel_name) do
      channel.present(user_id: 1, client_id: "a")
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

    channel1.present(user_id: 1, client_id: "a")
    channel2.present(user_id: 1, client_id: "a")

    start_time = Time.zone.now

    freeze_time start_time + PresenceChannel::DEFAULT_TIMEOUT / 2

    channel2.present(user_id: 2, client_id: "b")

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

  it 'only sends one `enter` and `leave` message' do
    channel = PresenceChannel.new("test")

    messages = MessageBus.track_publish(channel.message_bus_channel_name) do
      channel.present(user_id: 1, client_id: "a")
      channel.present(user_id: 1, client_id: "a")
    end
    expect(messages.map(&:data)).to contain_exactly(
      {
        "type" => "enter",
        "user_id" => 1,
      }
    )

    messages = MessageBus.track_publish(channel.message_bus_channel_name) do
      channel.leave(user_id: 1, client_id: "a")
      channel.leave(user_id: 1, client_id: "a")
    end
    expect(messages.map(&:data)).to contain_exactly(
      {
        "type" => "leave",
        "user_id" => 1,
      }
    )
  end

  it "will return the messagebus last_id in the state payload" do
    channel = PresenceChannel.new("test1")

    channel.present(user_id: 1, client_id: "a")
    channel.present(user_id: 2, client_id: "a")

    state = channel.state
    expect(state.user_ids).to contain_exactly(1, 2)
    expect(state.count).to eq(2)
    expect(state.message_bus_last_id).to eq(MessageBus.last_id(channel.message_bus_channel_name))
  end

end
