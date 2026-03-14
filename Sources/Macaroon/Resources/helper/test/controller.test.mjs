import test from "node:test";
import assert from "node:assert/strict";

import { RoonBridgeController } from "../src/controller.mjs";

class TestOutput {
  constructor() {
    this.events = [];
  }

  sendEvent(event, payload) {
    this.events.push({ event, payload });
  }
}

test("core.disconnect closes the active websocket connection", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);

  let closeCount = 0;
  controller.roon = {
    ws_connect({ onclose }) {
      return {
        transport: {
          close() {
            closeCount += 1;
            onclose?.();
          }
        }
      };
    },
    stop_discovery() {},
    disconnect_all() {}
  };

  await controller.handle({
    method: "connect.manual",
    params: {
      host: "10.0.0.2",
      port: 9330,
      persistedState: { pairedCoreID: null, tokens: {}, endpoints: {} }
    }
  });

  await controller.handle({
    method: "core.disconnect",
    params: {}
  });

  assert.equal(closeCount, 1);
  assert.deepEqual(output.events.at(-1), {
    event: "core.connectionChanged",
    payload: {
      status: {
        state: "disconnected"
      }
    }
  });
});

test("saved-server fallback starts discovery without triggering an extra reconnect loop", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);

  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;

  let wsConnectCount = 0;
  let startDiscoveryCount = 0;

  globalThis.setTimeout = (callback) => {
    callback();
    return Symbol("timeout");
  };
  globalThis.clearTimeout = () => {};

  controller.roon = {
    ws_connect({ onclose }) {
      wsConnectCount += 1;
      return {
        transport: {
          close() {
            onclose?.();
          }
        }
      };
    },
    start_discovery() {
      startDiscoveryCount += 1;
    },
    stop_discovery() {},
    disconnect_all() {}
  };

  try {
    await controller.handle({
      method: "connect.auto",
      params: {
        persistedState: {
          pairedCoreID: "core-1",
          tokens: { "core-1": "token-1" },
          endpoints: { "core-1": { host: "10.0.0.3", port: 9330 } }
        }
      }
    });
  } finally {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  }

  assert.equal(wsConnectCount, 1);
  assert.equal(startDiscoveryCount, 1);
  assert.equal(
    output.events.filter(({ event, payload }) =>
      event === "core.connectionChanged" &&
      payload.status.state === "connecting" &&
      payload.status.mode === "reconnecting"
    ).length,
    0
  );
});

test("saved-server reconnect normalizes persisted endpoint ports before websocket connect", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);

  let connectedPort = null;
  controller.roon = {
    ws_connect({ port }) {
      connectedPort = port;
      return {
        transport: {
          close() {}
        }
      };
    },
    stop_discovery() {},
    disconnect_all() {}
  };

  await controller.handle({
    method: "connect.auto",
    params: {
      persistedState: {
        pairedCoreID: "core-1",
        tokens: { "core-1": "token-1" },
        endpoints: { "core-1": { host: "10.0.0.3", port: "9330" } }
      }
    }
  });

  assert.equal(connectedPort, 9330);
});

test("performing a resolved context action ignores cleanup pop failures after success", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);
  let loadCount = 0;

  controller.core = {
    services: {
      RoonApiBrowse: {
        browse(options, callback) {
          if (options.item_key === "album-1") {
            callback(null, {
              action: "list",
              list: {
                title: "Actions",
                count: 1,
                level: 2,
                display_offset: 0,
                hint: "action_list"
              }
            });
            return;
          }

          if (options.item_key === "play-now") {
            callback(null, { action: "message", is_error: false, message: "Playing" });
            return;
          }

          if (options.pop_levels === 2) {
            callback("failed to pop after action");
            return;
          }

          callback(new Error(`Unexpected browse options: ${JSON.stringify(options)}`));
        },
        load(options, callback) {
          loadCount += 1;
          if (options.hierarchy !== "albums") {
            callback(new Error(`Unexpected hierarchy: ${options.hierarchy}`));
            return;
          }

          callback(null, {
            offset: 0,
            list: {
              title: "Actions",
              count: 1,
              level: 2,
              display_offset: 0,
              hint: "action_list"
            },
            items: [
              { title: "Play Now", item_key: "play-now", hint: "action" }
            ]
          });
        }
      }
    }
  };

  await assert.doesNotReject(async () => {
    await controller.handle({
      method: "browse.performAction",
      params: {
        hierarchy: "albums",
        sessionKey: "albums:album-1",
        itemKey: "album-1",
        zoneOrOutputID: "zone-1",
        contextItemKey: "album-1",
        actionTitle: "Play Now"
      }
    });
  });

  assert.equal(output.events.length, 0);
  assert.equal(loadCount, 1);
});

test("transport.seek forwards absolute seek requests", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);

  let observed = null;
  controller.core = {
    services: {
      RoonApiTransport: {
        seek(zoneOrOutputID, how, seconds, callback) {
          observed = { zoneOrOutputID, how, seconds };
          callback(false);
        }
      }
    }
  };

  await controller.handle({
    method: "transport.seek",
    params: {
      zoneOrOutputID: "zone-1",
      how: "absolute",
      seconds: 97
    }
  });

  assert.deepEqual(observed, {
    zoneOrOutputID: "zone-1",
    how: "absolute",
    seconds: 97
  });
});

test("transport.changeVolume forwards output volume requests", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);

  let observed = null;
  controller.core = {
    services: {
      RoonApiTransport: {
        change_volume(outputID, how, value, callback) {
          observed = { outputID, how, value };
          callback(false);
        }
      }
    }
  };

  await controller.handle({
    method: "transport.changeVolume",
    params: {
      outputID: "output-1",
      how: "absolute",
      value: -18.5
    }
  });

  assert.deepEqual(observed, {
    outputID: "output-1",
    how: "absolute",
    value: -18.5
  });
});

test("browse.submitInput refreshes the current list when Roon responds with replace_item", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);

  let loadCount = 0;
  const browseCalls = [];
  controller.core = {
    services: {
      RoonApiBrowse: {
        browse(options, callback) {
          browseCalls.push(options);

          if (options.hierarchy === "browse" && options.multi_session_key === "macaroon-search" && options.pop_all === true) {
            callback(null, {
              action: "list",
              list: {
                title: "Search",
                count: 1,
                level: 0,
                display_offset: 0,
                hint: null
              }
            });
            return;
          }

          if (
            options.hierarchy === "browse" &&
            options.multi_session_key === "macaroon-search" &&
            options.item_key === "search-box" &&
            options.input === "miles"
          ) {
            callback(null, {
              action: "replace_item",
              item: {
                title: "Search Library",
                item_key: "search-box",
                input_prompt: {
                  prompt: "Search Library",
                  action: "Go"
                }
              }
            });
            return;
          }

          callback(new Error(`Unexpected browse options: ${JSON.stringify(options)}`));
        },
        load(options, callback) {
          loadCount += 1;
          if (options.hierarchy !== "browse" || options.multi_session_key !== "macaroon-search") {
            callback(new Error(`Unexpected hierarchy: ${options.hierarchy}`));
            return;
          }

          callback(null, {
            offset: options.offset ?? 0,
            list: {
              title: "Search",
              count: 1,
              level: 0,
              display_offset: 0,
              hint: null
            },
            items: loadCount === 1 ? [
              {
                title: "Search Library",
                item_key: "search-box",
                input_prompt: {
                  prompt: "Search Library",
                  action: "Go"
                }
              }
            ] : [
              {
                title: "Miles Davis",
                item_key: "artist-miles",
                hint: "list"
              }
            ]
          });
        }
      }
    }
  };

  await controller.handle({
    method: "browse.home",
    params: {
      hierarchy: "search",
      zoneOrOutputID: null
    }
  });

  await controller.handle({
    method: "browse.submitInput",
    params: {
      hierarchy: "search",
      itemKey: "search-box",
      input: "miles",
      zoneOrOutputID: null
    }
  });

  const listChangedEvents = output.events.filter(({ event }) => event === "browse.listChanged");
  assert.equal(listChangedEvents.length, 2);
  assert.equal(listChangedEvents.at(-1).payload.page.items[0].title, "Miles Davis");
  assert.deepEqual(
    browseCalls.map((options) => ({
      hierarchy: options.hierarchy,
      multiSessionKey: options.multi_session_key ?? null,
      popAll: options.pop_all ?? false,
      itemKey: options.item_key ?? null,
      input: options.input ?? null
    })),
    [
      {
        hierarchy: "browse",
        multiSessionKey: "macaroon-search",
        popAll: true,
        itemKey: null,
        input: null
      },
      {
        hierarchy: "browse",
        multiSessionKey: "macaroon-search",
        popAll: false,
        itemKey: "search-box",
        input: "miles"
      }
    ]
  );
});

test("browse.contextActions uses the dedicated search browse session for cleanup", async () => {
  const output = new TestOutput();
  const controller = new RoonBridgeController(output);

  const browseCalls = [];
  controller.browseSessions.set("search", {
    list: {
      title: "Search",
      count: 6,
      level: 2,
      display_offset: 0,
      hint: null
    },
    selectedZoneID: "zone-1",
    requestHierarchy: "browse",
    multiSessionKey: "macaroon-search"
  });

  controller.core = {
    services: {
      RoonApiBrowse: {
        browse(options, callback) {
          browseCalls.push(options);

          if (
            options.hierarchy === "browse" &&
            options.multi_session_key === "macaroon-search" &&
            options.item_key === "artist-nirvana"
          ) {
            callback(null, {
              action: "list",
              list: {
                title: "Play Options",
                count: 1,
                level: 3,
                display_offset: 0,
                hint: "action_list"
              }
            });
            return;
          }

          if (
            options.hierarchy === "browse" &&
            options.multi_session_key === "macaroon-search" &&
            options.pop_levels === 1
          ) {
            callback(null, { action: "none" });
            return;
          }

          callback(new Error(`Unexpected browse options: ${JSON.stringify(options)}`));
        },
        load(options, callback) {
          callback(null, {
            offset: 0,
            list: {
              title: "Play Options",
              count: 1,
              level: 3,
              display_offset: 0,
              hint: "action_list"
            },
            items: [
              {
                title: "Play Now",
                item_key: "play-now",
                hint: "action"
              }
            ]
          });
        }
      }
    }
  };

  const result = await controller.handle({
    method: "browse.contextActions",
    params: {
      hierarchy: "search",
      itemKey: "artist-nirvana",
      zoneOrOutputID: "zone-1"
    }
  });

  assert.equal(result.actions[0].title, "Play Now");
  assert.deepEqual(
    browseCalls.map((options) => ({
      hierarchy: options.hierarchy,
      multiSessionKey: options.multi_session_key ?? null,
      itemKey: options.item_key ?? null,
      popLevels: options.pop_levels ?? null
    })),
    [
      {
        hierarchy: "browse",
        multiSessionKey: "macaroon-search",
        itemKey: "artist-nirvana",
        popLevels: null
      },
      {
        hierarchy: "browse",
        multiSessionKey: "macaroon-search",
        itemKey: null,
        popLevels: 1
      }
    ]
  );
});
