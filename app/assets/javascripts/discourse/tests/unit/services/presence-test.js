import {
  acceptance,
  publishToMessageBus,
} from "discourse/tests/helpers/qunit-helpers";
import { test } from "qunit";

acceptance("Presence - Subscribing", function (needs) {
  needs.pretender((server, helper) => {
    server.get("/presence/get", () => {
      return helper.response({
        users: [1, 2, 3],
        last_message_id: 1,
      });
    });
  });

  test("subscribing and receiving updates", async function (assert) {
    let presenceService = this.container.lookup("service:presence");
    let channel = presenceService.getChannel("mychannel");
    assert.equal(channel.name, "mychannel");

    await channel.subscribe({
      users: [1, 2, 3],
      last_message_id: 1,
    });

    assert.equal(channel.users.length, 3, "it starts with three users");

    publishToMessageBus(
      "/presence/mychannel",
      {
        type: "leave",
        user_id: 1,
      },
      0,
      2
    );

    assert.equal(channel.users.length, 2, "one user is removed");

    publishToMessageBus(
      "/presence/mychannel",
      {
        type: "enter",
        user_id: 1,
      },
      0,
      3
    );

    assert.equal(channel.users.length, 3, "one user is added");
  });

  test("fetches data when no initial state", async function (assert) {
    let presenceService = this.container.lookup("service:presence");
    let channel = presenceService.getChannel("mychannel");

    await channel.subscribe();

    assert.equal(channel.users.length, 3, "loads initial state");

    publishToMessageBus(
      "/presence/mychannel",
      {
        type: "leave",
        user_id: 1,
      },
      0,
      2
    );

    assert.equal(
      channel.users.length,
      2,
      "updates following messagebus message"
    );

    publishToMessageBus(
      "/presence/mychannel",
      {
        type: "leave",
        user_id: 2,
      },
      0,
      99
    );

    await channel._resubscribePromise;

    assert.equal(
      channel.users.length,
      3,
      "detects missed messagebus message, fetches data from server"
    );
  });
});

acceptance("Presence - Entering and Leaving", function (needs) {
  needs.user();

  const requests = [];
  needs.hooks.afterEach(() => requests.clear());
  needs.pretender((server, helper) => {
    server.post("/presence/update", (request) => {
      const body = new URLSearchParams(request.requestBody);
      requests.push(body);
      return helper.response({});
    });
  });

  test("can join and leave channels", async function (assert) {
    const presenceService = this.container.lookup("service:presence");
    const channel = presenceService.getChannel("mychannel");

    await channel.enter();
    assert.equal(requests.length, 1, "updated the server for enter");
    let presentChannels = requests.pop().getAll("present_channels[]");
    assert.deepEqual(
      presentChannels,
      ["mychannel"],
      "included the correct present channel"
    );

    await channel.leave();
    assert.equal(requests.length, 1, "updated the server for leave");
    const request = requests.pop();
    presentChannels = request.getAll("present_channels[]");
    const leaveChannels = request.getAll("leave_channels[]");
    assert.deepEqual(presentChannels, [], "included no present channels");
    assert.deepEqual(
      leaveChannels,
      ["mychannel"],
      "included the correct leave channel"
    );
  });
});
