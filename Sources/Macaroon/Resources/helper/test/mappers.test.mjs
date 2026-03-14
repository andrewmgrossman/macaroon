import test from "node:test";
import assert from "node:assert/strict";

import { toBrowsePage, toZoneSummary } from "../src/mappers.mjs";

test("toZoneSummary maps transport flags and now playing", () => {
  const summary = toZoneSummary({
    zone_id: "zone-1",
    display_name: "Office",
    state: "playing",
    is_play_allowed: true,
    is_pause_allowed: true,
    is_next_allowed: true,
    is_previous_allowed: false,
    is_seek_allowed: true,
    outputs: [{
      output_id: "output-1",
      zone_id: "zone-1",
      display_name: "Office DAC",
      volume: {
        type: "db",
        min: -80,
        max: 0,
        value: -21.5,
        step: 0.5,
        is_muted: false
      }
    }],
    now_playing: {
      image_key: "abc123",
      seek_position: 12,
      length: 180,
      three_line: {
        line1: "Track",
        line2: "Artist",
        line3: "Album"
      }
    }
  });

  assert.equal(summary.zoneID, "zone-1");
  assert.equal(summary.capabilities.canNext, true);
  assert.equal(summary.capabilities.canPrevious, false);
  assert.equal(summary.nowPlaying?.title, "Track");
  assert.equal(summary.outputs[0].volume?.value, -21.5);
});

test("toBrowsePage maps list metadata and items", () => {
  const page = toBrowsePage({
    hierarchy: "browse",
    list: { title: "Library", subtitle: null, count: 1, level: 0, display_offset: 0, hint: null },
    items: [{ title: "Albums", subtitle: "42", image_key: null, item_key: "albums", hint: "list" }],
    offset: 0,
    selectedZoneID: "zone-1"
  });

  assert.equal(page.list.title, "Library");
  assert.equal(page.items[0].itemKey, "albums");
  assert.equal(page.selectedZoneID, "zone-1");
});
