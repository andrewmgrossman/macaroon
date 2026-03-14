import readline from "node:readline";
import fs from "node:fs/promises";
import path from "node:path";
import { RoonBridgeController } from "./controller.mjs";

class JsonLineOutput {
  sendEvent(event, payload) {
    const line = JSON.stringify({ event, payload });
    captureLine("event", line);
    process.stdout.write(`${line}\n`);
  }

  sendResponse(id, result = {}) {
    const line = JSON.stringify({ id, result });
    captureLine("response", line);
    process.stdout.write(`${line}\n`);
  }

  sendError(id, error) {
    const line = JSON.stringify({
      id,
      error: {
        code: error.code ?? "bridge.error",
        message: error.message ?? String(error)
      }
    });
    captureLine("error", line);
    process.stdout.write(`${line}\n`);
  }
}

const captureDirectory = process.env.MACAROON_HELPER_CAPTURE_DIR?.trim();
const helperTranscriptPath = captureDirectory
  ? path.join(captureDirectory, "helper-lines.jsonl")
  : null;

async function captureLine(kind, payload) {
  if (!helperTranscriptPath) {
    return;
  }

  const entry = JSON.stringify({
    timestamp: new Date().toISOString(),
    kind,
    payload
  });

  try {
    await fs.mkdir(path.dirname(helperTranscriptPath), { recursive: true });
    await fs.appendFile(helperTranscriptPath, `${entry}\n`, "utf8");
  } catch {
    // Ignore capture failures.
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
  void captureLine("request", line);

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
