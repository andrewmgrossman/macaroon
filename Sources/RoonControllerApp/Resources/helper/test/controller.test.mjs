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
