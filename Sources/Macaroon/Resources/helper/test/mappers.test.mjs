import test from "node:test";
import assert from "node:assert/strict";

import { toBrowsePage, toQueueState, toZoneSummary } from "../src/mappers.mjs";

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

test("toQueueState maps queue items and current item identity", () => {
  const queue = toQueueState({
    zone_id: "zone-1",
    title: "Up Next",
    count: 2,
    now_playing_queue_item_id: "item-2",
    items: [
      {
        queue_item_id: "item-1",
        image_key: "art-1",
        length: 120,
        three_line: {
          line1: "Song One",
          line2: "Artist One",
          line3: "Album One"
        }
      },
      {
        queue_item_id: "item-2",
        image_key: "art-2",
        length: 240,
        two_line: {
          line1: "Song Two",
          line2: "Artist Two"
        }
      }
    ]
  }, "zone-1");

  assert.equal(queue.zoneID, "zone-1");
  assert.equal(queue.totalCount, 2);
  assert.equal(queue.currentQueueItemID, "item-2");
  assert.equal(queue.items[0].title, "Song One");
  assert.equal(queue.items[1].isCurrent, true);
});

test("toQueueState merges queue delta updates", () => {
  const initial = toQueueState({
    zone_id: "zone-1",
    title: "Up Next",
    count: 0,
    items: []
  }, "zone-1");

  const changed = toQueueState({
    zone_id: "zone-1",
    count: 2,
    now_playing_queue_item_id: "item-1",
    items_added: [
      {
        queue_item_id: "item-1",
        three_line: {
          line1: "First Track",
          line2: "Artist A",
          line3: "Album A"
        }
      },
      {
        queue_item_id: "item-2",
        three_line: {
          line1: "Second Track",
          line2: "Artist B",
          line3: "Album B"
        }
      }
    ]
  }, "zone-1", initial);

  assert.equal(changed.totalCount, 2);
  assert.equal(changed.items.length, 2);
  assert.equal(changed.items[0].title, "First Track");
  assert.equal(changed.items[0].isCurrent, true);
});

test("toQueueState applies indexed queue change operations", () => {
  const initial = toQueueState({
    zone_id: "zone-1",
    title: "Up Next",
    count: 3,
    items: [
      {
        queue_item_id: 1,
        three_line: { line1: "Old A", line2: "Artist A", line3: "Album A" }
      },
      {
        queue_item_id: 2,
        three_line: { line1: "Old B", line2: "Artist B", line3: "Album B" }
      },
      {
        queue_item_id: 3,
        three_line: { line1: "Old C", line2: "Artist C", line3: "Album C" }
      }
    ]
  }, "zone-1");

  const changed = toQueueState({
    zone_id: "zone-1",
    changes: [
      { operation: "remove", index: 0, count: 3 },
      {
        operation: "insert",
        index: 0,
        items: [
          {
            queue_item_id: 10,
            three_line: { line1: "New A", line2: "Artist X", line3: "Album X" }
          },
          {
            queue_item_id: 11,
            three_line: { line1: "New B", line2: "Artist Y", line3: "Album Y" }
          }
        ]
      }
    ]
  }, "zone-1", initial);

  assert.equal(changed.items.length, 2);
  assert.equal(changed.items[0].queueItemID, "10");
  assert.equal(changed.items[1].title, "New B");
  assert.equal(changed.totalCount, 2);
});
