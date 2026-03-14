import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";

export function mapConnectionStatus(status, core = null) {
  switch (status) {
    case "disconnected":
      return { state: "disconnected" };
    case "connecting":
      return { state: "connecting", mode: typeof core === "string" ? core : "discovery" };
    case "manual":
      return { state: "connecting", mode: "manual" };
    case "authorizing":
      return { state: "authorizing", core };
    case "connected":
      return { state: "connected", core };
    default:
      return { state: "error", message: status };
  }
}

export function toCoreSummary(core, host = null, port = null) {
  return {
    coreID: core.core_id,
    displayName: core.display_name,
    displayVersion: core.display_version,
    host,
    port
  };
}

export function toZoneSummary(zone) {
  const nowPlaying = zone.now_playing
    ? {
        title:
          zone.now_playing.three_line?.line1 ??
          zone.now_playing.two_line?.line1 ??
          zone.now_playing.one_line?.line1 ??
          "Unknown",
        subtitle:
          zone.now_playing.three_line?.line2 ??
          zone.now_playing.two_line?.line2 ??
          null,
        detail: zone.now_playing.three_line?.line3 ?? null,
        imageKey: zone.now_playing.image_key ?? null,
        seekPosition: zone.now_playing.seek_position ?? null,
        length: zone.now_playing.length ?? null,
        lines: zone.now_playing.three_line
          ? {
              line1: zone.now_playing.three_line.line1,
              line2: zone.now_playing.three_line.line2 ?? null,
              line3: zone.now_playing.three_line.line3 ?? null
            }
          : null
      }
    : null;

  return {
    zoneID: zone.zone_id,
    displayName: zone.display_name,
    state: zone.state,
    outputs: (zone.outputs ?? []).map((output) => ({
      outputID: output.output_id,
      zoneID: output.zone_id,
      displayName: output.display_name,
      volume: output.volume
        ? {
            type: output.volume.type ?? "number",
            min: output.volume.min ?? null,
            max: output.volume.max ?? null,
            value: output.volume.value ?? null,
            step: output.volume.step ?? null,
            isMuted: output.volume.is_muted ?? null
          }
        : null
    })),
    capabilities: {
      canPlayPause: Boolean(zone.is_play_allowed || zone.is_pause_allowed),
      canPause: Boolean(zone.is_pause_allowed),
      canPlay: Boolean(zone.is_play_allowed),
      canStop: Boolean(zone.is_pause_allowed || zone.state !== "stopped"),
      canNext: Boolean(zone.is_next_allowed),
      canPrevious: Boolean(zone.is_previous_allowed),
      canSeek: Boolean(zone.is_seek_allowed)
    },
    nowPlaying
  };
}

export function toBrowseItem(item) {
  const lines = browseLinesForItem(item);
  return {
    title: lines.title,
    subtitle: lines.subtitle,
    imageKey: item.image_key ?? null,
    itemKey: item.item_key ?? null,
    hint: item.hint ?? null,
    detail: lines.detail,
    length: item.length ?? item.duration ?? null,
    inputPrompt: item.input_prompt
      ? {
          prompt: item.input_prompt.prompt,
          action: item.input_prompt.action,
          value: item.input_prompt.value ?? null,
          isPassword: Boolean(item.input_prompt.is_password)
        }
      : null
  };
}

export function toBrowsePage({ hierarchy, list, items, offset, selectedZoneID }) {
  return {
    hierarchy,
    list: {
      title: list.title,
      subtitle: list.subtitle ?? null,
      count: list.count,
      level: list.level,
      displayOffset: list.display_offset ?? 0,
      hint: list.hint ?? null,
      imageKey: list.image_key ?? null
    },
    items: items.map(toBrowseItem),
    offset,
    selectedZoneID
  };
}

function browseLinesForItem(item) {
  if (item.three_line) {
    return {
      title: item.three_line.line1 ?? item.title ?? "Unknown",
      subtitle: item.three_line.line2 ?? item.subtitle ?? null,
      detail: item.three_line.line3 ?? item.detail ?? null
    };
  }

  if (item.two_line) {
    return {
      title: item.two_line.line1 ?? item.title ?? "Unknown",
      subtitle: item.two_line.line2 ?? item.subtitle ?? null,
      detail: item.detail ?? null
    };
  }

  if (item.one_line) {
    return {
      title: item.one_line.line1 ?? item.title ?? "Unknown",
      subtitle: item.subtitle ?? null,
      detail: item.detail ?? null
    };
  }

  return {
    title: item.title ?? "Unknown",
    subtitle: item.subtitle ?? null,
    detail: item.detail ?? null
  };
}

function queueLinesForItem(item) {
  if (item.three_line) {
    return {
      title: item.three_line.line1 ?? "Unknown",
      subtitle: item.three_line.line2 ?? null,
      detail: item.three_line.line3 ?? null
    };
  }

  if (item.two_line) {
    return {
      title: item.two_line.line1 ?? "Unknown",
      subtitle: item.two_line.line2 ?? null,
      detail: null
    };
  }

  if (item.one_line) {
    return {
      title: item.one_line.line1 ?? "Unknown",
      subtitle: null,
      detail: null
    };
  }

  return {
    title: item.title ?? "Unknown",
    subtitle: item.subtitle ?? null,
    detail: item.detail ?? null
  };
}

function toQueueItemSummary(item, inferredCurrentQueueItemID, fallbackIndex = 0) {
  const queueItemID = String(item.queue_item_id ?? item.item_id ?? item.id ?? `queue-item-${fallbackIndex}`);
  const lines = queueLinesForItem(item);
  return {
    queueItemID,
    title: lines.title,
    subtitle: lines.subtitle,
    detail: lines.detail,
    imageKey: item.image_key ?? null,
    length: item.length ?? item.duration ?? null,
    isCurrent:
      item.is_current === true ||
      item.now_playing === true ||
      (inferredCurrentQueueItemID !== null && queueItemID === inferredCurrentQueueItemID)
  };
}

export function toQueueState(message, zoneOrOutputID, previousState = null) {
  const inferredCurrentQueueItemID =
    message.now_playing_queue_item_id ??
    message.current_queue_item_id ??
    message.queue_item_id ??
    message.items?.find((item) => item.is_current === true || item.now_playing === true)?.queue_item_id ??
    message.queue_items?.find((item) => item.is_current === true || item.now_playing === true)?.queue_item_id ??
    previousState?.currentQueueItemID ??
    null;

  const fullItemPayload = message.items ?? message.queue_items ?? message.queue?.items ?? null;
  let items = fullItemPayload
    ? fullItemPayload.map((item, index) => toQueueItemSummary(item, inferredCurrentQueueItemID, index))
    : (previousState?.items ?? []).map((item) => ({
        ...item,
        isCurrent: inferredCurrentQueueItemID !== null && item.queueItemID === inferredCurrentQueueItemID
      }));

  if (fullItemPayload == null) {
    const byID = new Map(items.map((item) => [item.queueItemID, item]));

    for (const changed of message.items_changed ?? []) {
      const summary = toQueueItemSummary(changed, inferredCurrentQueueItemID, byID.size);
      byID.set(summary.queueItemID, summary);
    }

    for (const added of message.items_added ?? []) {
      const summary = toQueueItemSummary(added, inferredCurrentQueueItemID, byID.size);
      byID.set(summary.queueItemID, summary);
    }

    for (const removed of message.items_removed ?? []) {
      const removedID = String(removed.queue_item_id ?? removed.item_id ?? removed.id ?? removed);
      byID.delete(removedID);
    }

    items = Array.from(byID.values()).map((item) => ({
      ...item,
      isCurrent: inferredCurrentQueueItemID !== null && item.queueItemID === inferredCurrentQueueItemID
    }));
  }

  if (Array.isArray(message.changes) && message.changes.length > 0) {
    let orderedItems = [...(previousState?.items ?? items)];

    for (const change of message.changes) {
      if (change.operation === "remove") {
        const index = Math.max(0, change.index ?? 0);
        const count = Math.max(0, change.count ?? 0);
        orderedItems.splice(index, count);
        continue;
      }

      if (change.operation === "insert") {
        const index = Math.max(0, change.index ?? orderedItems.length);
        const insertedItems = (change.items ?? []).map((item, itemIndex) =>
          toQueueItemSummary(item, inferredCurrentQueueItemID, index + itemIndex)
        );
        orderedItems.splice(index, 0, ...insertedItems);
        continue;
      }
    }

    items = orderedItems.map((item, itemIndex) => ({
      ...item,
      queueItemID: item.queueItemID ?? `queue-item-${itemIndex}`,
      isCurrent: inferredCurrentQueueItemID !== null
        ? item.queueItemID === inferredCurrentQueueItemID
        : item.isCurrent
    }));
  }

  const currentQueueItemID =
    items.find((item) => item.isCurrent)?.queueItemID ??
    inferredCurrentQueueItemID;

  return {
    zoneID: String(message.zone_id ?? zoneOrOutputID),
    title: message.title ?? message.display_name ?? previousState?.title ?? "Queue",
    totalCount:
      message.count ??
      message.total_count ??
      message.queue_count ??
      items.length,
    currentQueueItemID,
    items
  };
}

export async function saveArtwork(imageKey, bytes, extension = "jpg") {
  const directory = path.join(os.tmpdir(), "macaroon-artwork");
  await fs.mkdir(directory, { recursive: true });
  const hash = crypto.createHash("sha1").update(imageKey).digest("hex");
  const fileURL = path.join(directory, `${hash}.${extension}`);
  await fs.writeFile(fileURL, bytes);
  return fileURL;
}
