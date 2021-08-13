import Service from "@ember/service";
import EmberObject, { computed } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { cancel, later, throttle } from "@ember/runloop";
import Session from "discourse/models/session";
import { Promise } from "rsvp";
import { isTesting } from "discourse-common/config/environment";

const PRESENCE_INTERVAL_S = 30;
const PRESENCE_THROTTLE_MS = 100;

function createPromiseProxy() {
  const promiseProxy = {};
  promiseProxy.promise = new Promise((resolve, reject) => {
    promiseProxy.resolve = resolve;
    promiseProxy.reject = reject;
  });
  return promiseProxy;
}

class PresenceChannel extends EmberObject {
  init({ name, presenceService }) {
    super.init(...arguments);
    this.name = name;
    this.set("users", []);
    this.presenceService = presenceService;
  }

  @computed("users.[]")
  get count() {
    return this.users.length;
  }

  get present() {
    return this.presenceService._presentChannels.has(this.name);
  }

  @computed("_subscribedCallback")
  get subscribed() {
    return !!this._subscribedCallback;
  }

  async enter() {
    await this.presenceService.enter(this.name);
  }

  async leave() {
    await this.presenceService.leave(this.name);
  }

  async subscribe(initialData = null) {
    if (this.subscribed) {
      return;
    }

    if (!initialData) {
      initialData = await ajax("/presence/get", {
        data: {
          channel: this.name,
        },
      });
    }
    this.set("users", initialData.users);
    this.lastSeenId = initialData.last_message_id;

    let callback = (data, global_id, message_id) => {
      this._processMessage(data, global_id, message_id);
    };
    this.presenceService.subscribe(this.name, callback, this.lastSeenId);

    this.set("_subscribedCallback", callback);
  }

  unsubscribe() {
    if (this.subscribed) {
      this.presenceService.unsubscribe(this.name, this._subscribedCallback);
      this.set("_subscribedCallback", null);
    }
  }

  async _processMessage(data, global_id, message_id) {
    if (message_id !== this.lastSeenId + 1) {
      // eslint-disable-next-line no-console
      console.log(
        `PresenceChannel '${
          this.name
        }' dropped message (received ${message_id}, expecting ${
          this.lastSeenId + 1
        }), resyncing...`
      );

      this.unsubscribe();

      // Stored at object level for tests to hook in
      this._resubscribePromise = this.subscribe();
      await this._resubscribePromise;
      delete this._resubscribePromise;

      return;
    } else {
      this.lastSeenId = message_id;
    }

    if (data.type === "leave") {
      this.users.removeObject(data.user_id);
    } else if (data.type === "enter") {
      this.users.addObject(data.user_id);
    } else {
      throw `Unknown message type: ${data}`;
    }
  }
}

export default class PresenceService extends Service {
  init() {
    super.init(...arguments);
    this._presentChannels = new Set();
    this._queuedEvents = [];
    window.addEventListener("beforeunload", () => {
      this._beaconLeaveAll();
    });
  }

  getChannel(channelName) {
    return PresenceChannel.create({
      name: channelName,
      presenceService: this,
    });
  }

  async enter(channelName) {
    if (!this.currentUser) {
      throw "Must be logged in to enter presence channel";
    }

    if (this._presentChannels.has(channelName)) {
      return;
    }

    const promiseProxy = createPromiseProxy();

    this._presentChannels.add(channelName);
    this._queuedEvents.push({
      channel: channelName,
      type: "enter",
      promiseProxy: promiseProxy,
    });

    this._requestFastUpdate();

    await promiseProxy.promise;
  }

  async leave(channelName) {
    if (!this.currentUser) {
      throw "Must be logged in to leave presence channel";
    }

    if (!this._presentChannels.has(channelName)) {
      return;
    }

    const promiseProxy = createPromiseProxy();

    this._presentChannels.delete(channelName);
    this._queuedEvents.push({
      channel: channelName,
      type: "leave",
      promiseProxy: promiseProxy,
    });

    this._requestFastUpdate();

    await promiseProxy.promise;
  }

  subscribe(channelName, callback, lastSeenId) {
    this.messageBus.subscribe(`/presence/${channelName}`, callback, lastSeenId);
  }

  unsubscribe(channelName, callback) {
    this.messageBus.unsubscribe(`/presence/${channelName}`, callback);
  }

  _beaconLeaveAll() {
    if (isTesting()) {
      return;
    }
    this._dedupQueue();
    const channelsToLeave = this._queuedEvents
      .filter((e) => e.type === "leave")
      .map((e) => e.channel);

    const data = new FormData();
    data.append("client_id", this.messageBus.clientId);
    this._presentChannels.forEach((ch) => data.append("leave_channels[]", ch));
    channelsToLeave.forEach((ch) => data.append("leave_channels[]", ch));

    data.append("authenticity_token", Session.currentProp("csrfToken"));
    navigator.sendBeacon("/presence/update", data);
  }

  _dedupQueue() {
    const deduplicated = {};
    this._queuedEvents.forEach((e) => {
      if (deduplicated[e.channel]) {
        deduplicated[e.channel].promiseProxy.resolve(e.promiseProxy.promise);
      }
      deduplicated[e.channel] = e;
    });
    this._queuedEvents = Object.values(deduplicated);
  }

  async _updateServer() {
    this._updateRunning = true;
    this._fastUpdateRequired = false;

    if (this._nextUpdateTimer) {
      cancel(this._nextUpdateTimer);
      this._nextUpdateTimer = null;
    }

    this._dedupQueue();
    const queue = this._queuedEvents;
    this._queuedEvents = [];

    try {
      const channelsToLeave = queue
        .filter((e) => e.type === "leave")
        .map((e) => e.channel);

      await ajax("/presence/update", {
        data: {
          client_id: this.messageBus.clientId,
          present_channels: [...this._presentChannels],
          leave_channels: channelsToLeave,
        },
        method: "POST",
      });

      queue.forEach((e) => {
        // TODO: Once we add security, some of
        // these promises should be rejected
        e.promiseProxy.resolve();
      });
    } catch {
      // Updating server failed. Put the failed events
      // back in the queue for next time
      this._queuedEvents.unshift(...queue);
    } finally {
      this._updateRunning = false;
      this._scheduleNextUpdate();
    }
  }

  _throttledUpdateServer() {
    throttle(this, this._updateServer, PRESENCE_THROTTLE_MS, false);
  }

  _requestFastUpdate() {
    this._fastUpdateRequired = true;
    this._scheduleNextUpdate();
  }

  _scheduleNextUpdate() {
    if (this._updateRunning) {
      return;
    } else if (this._fastUpdateRequired) {
      this._throttledUpdateServer();
    } else if (!this._nextUpdateTimer && !isTesting()) {
      this._nextUpdateTimer = later(
        this,
        this._throttledUpdateServer,
        PRESENCE_INTERVAL_S * 1000
      );
    }
  }
}
