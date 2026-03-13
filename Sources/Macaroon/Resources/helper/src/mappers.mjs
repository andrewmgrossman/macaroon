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
      displayName: output.display_name
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
  return {
    title: item.title,
    subtitle: item.subtitle ?? null,
    imageKey: item.image_key ?? null,
    itemKey: item.item_key ?? null,
    hint: item.hint ?? null,
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
      hint: list.hint ?? null
    },
    items: items.map(toBrowseItem),
    offset,
    selectedZoneID
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
