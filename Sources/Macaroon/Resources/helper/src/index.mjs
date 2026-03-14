import readline from "node:readline";
import { RoonBridgeController } from "./controller.mjs";

class JsonLineOutput {
  sendEvent(event, payload) {
    process.stdout.write(`${JSON.stringify({ event, payload })}\n`);
  }

  sendResponse(id, result = {}) {
    process.stdout.write(`${JSON.stringify({ id, result })}\n`);
  }

  sendError(id, error) {
    process.stdout.write(
      `${JSON.stringify({
        id,
        error: {
          code: error.code ?? "bridge.error",
          message: error.message ?? String(error)
        }
      })}\n`
    );
  }
}

const output = new JsonLineOutput();
const controller = new RoonBridgeController(output);
let isShuttingDown = false;

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity
});

rl.on("line", async (line) => {
  if (!line.trim()) {
    return;
  }

  let message;
  try {
    message = JSON.parse(line);
  } catch {
    output.sendEvent("error.raised", {
      code: "bridge.invalid_json",
      message: "Received malformed JSON from the host process."
    });
    return;
  }

  try {
    const result = await controller.handle(message);
    output.sendResponse(message.id, result ?? {});
  } catch (error) {
    output.sendError(message.id, error);
  }
});

process.on("uncaughtException", (error) => {
  output.sendEvent("error.raised", {
    code: "bridge.uncaught_exception",
    message: error.message
  });
});

process.on("unhandledRejection", (reason) => {
  output.sendEvent("error.raised", {
    code: "bridge.unhandled_rejection",
    message: reason instanceof Error ? reason.message : String(reason)
  });
});

async function shutdown(exitCode = 0) {
  if (isShuttingDown) {
    return;
  }
  isShuttingDown = true;
  try {
    controller.shutdown();
  } finally {
    rl.close();
    process.exit(exitCode);
  }
}

rl.on("close", () => {
  if (isShuttingDown) {
    return;
  }
  void shutdown(0);
});

process.on("SIGTERM", () => {
  void shutdown(0);
});

process.on("SIGINT", () => {
  void shutdown(0);
});
