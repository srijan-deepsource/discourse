# frozen_string_literal: true

class PresenceController < ApplicationController
  skip_before_action :check_xhr
  before_action :ensure_logged_in, only: [:update]

  def get
    name = params.require(:channel)
    channel = PresenceChannel.new(name)
    message_bus_channel_name = channel.message_bus_channel_name

    state = channel.state

    render json: {
      users: state.user_ids,
      last_message_id: state.message_bus_last_id
    }
  end

  def update
    client_id = params[:client_id]
    raise Discourse::InvalidParameters.new(:client_id) if !client_id.is_a?(String) || client_id.blank?

    present_channels = params[:present_channels]
    if present_channels && !(present_channels.is_a?(Array) && present_channels.all? { |c| c.is_a? String })
      raise Discourse::InvalidParameters.new(:present_channels)
    end

    leave_channels = params[:leave_channels]
    if leave_channels && !(leave_channels.is_a?(Array) && leave_channels.all? { |c| c.is_a? String })
      raise Discourse::InvalidParameters.new(:leave_channels)
    end

    present_channels&.each do |name|
      PresenceChannel.new(name).present(user_id: current_user.id, client_id: params[:client_id])
    end

    leave_channels&.each do |name|
      PresenceChannel.new(name).leave(user_id: current_user.id, client_id: params[:client_id])
    end

    render json: success_json
  end

end
