# Plan: Replace the JS Bridge with a Native Swift Roon Client Layer

## Summary
Replace the Node helper with a native Swift implementation behind the existing `BridgeService` seam, so `AppModel` and most UI code can stay intact during the migration. The native layer should preserve the current request/event contract at first, then remove the helper process, shell script, and Node resources only after parity and replay-based verification are complete.

The rewrite should be split into two tracks:
- production runtime: native Swift discovery, websocket transport, registry/pairing, browse, transport, and image support
- offline verification: protocol codecs, replay fixtures, fake discovery, fake websocket Core, and UI/state tests that do not require access to a live Roon Core

## Implementation Changes
### 1. Preserve the current app seam during cutover
- Keep `BridgeService`, `BridgeEventEnvelope`, request param types, and shared models as the app-facing contract for phase 1.
- Add a new `NativeRoonBridgeService` that conforms to `BridgeService` and emits the same events/results as the current helper-backed service.
- Change `AppModel.makeBridgeService()` to instantiate the native service by default.
- Keep the current mock bridge for UI development and offline UI tests.
- Keep the JS helper code in-tree only as a temporary oracle until parity is proven; do not route production app traffic through it once the native service exists.

### 2. Implement the native protocol stack in Swift
Create native Swift subsystems with strict separation of concerns:
- `RoonDiscoveryClient`
  - Implement SOOD v2 discovery over UDP multicast `239.255.90.90:9003` plus per-interface broadcast, matching the current helper behavior.
  - Track discovered Core endpoints, dedupe by `unique_id`, and expose discovery events to the bridge layer.
  - Support direct reconnect to a persisted endpoint before falling back to discovery.
- `RoonWebSocketTransport`
  - Use `URLSessionWebSocketTask` for runtime transport.
  - Implement heartbeat/ping handling equivalent to the JS transport behavior.
  - Expose connection lifecycle callbacks and clean shutdown semantics.
- `MooCodec`
  - Encode/decode the Roon MOO wire format, including request line, headers, content length/type, JSON bodies, binary payloads, request IDs, and incremental frame parsing.
  - Support request/response correlation plus subscription continuations and completes.
- `RoonRegistryClient`
  - Implement `/info`, `/register`, persisted token reuse, pairing state, and connected Core summary mapping.
  - Preserve current semantics for `connect.auto`, `connect.manual`, reconnect backoff, saved endpoint persistence, and `authorizationRequired`.
  - Only emit `authorizationRequired` when user action in Roon is truly needed.
- `RoonServiceClients`
  - `BrowseClient`: browse/load operations, stack state per hierarchy, prompt submission, paging, action-list resolution, and action execution in the current browse session.
  - `TransportClient`: zone subscription, now-playing updates, and transport controls.
  - `ImageClient`: image fetch and file-backed artwork cache compatible with current app usage.
- `NativeRoonBridgeCoordinator`
  - Translate `BridgeRequest` methods into native client calls.
  - Emit the same event payloads the app already consumes: connection changes, zones snapshot/changes, browse list changes, item replace/remove, now playing, session persist, and error events.

### 3. Keep state and model behavior stable
- Preserve these app-visible models as the canonical shared surface:
  - `CoreSummary`
  - `ZoneSummary`
  - `OutputSummary`
  - `NowPlaying`
  - `BrowsePage` / `BrowseItem`
  - `PersistedSessionState`
  - `ConnectionStatusPayload`
- Keep session persistence in the current app support file and continue storing:
  - paired Core ID
  - authorization tokens
  - last known endpoint per Core
- Preserve current connection policy:
  - try saved endpoint first
  - fall back to discovery
  - one active paired Core at a time
  - exponential backoff for unintentional disconnects
- Preserve current browse semantics:
  - paging via `load`
  - action execution in the current session, not a synthetic detached session
  - search via the existing `search` hierarchy
  - zone/output-targeted playback actions

### 4. Use the JS helper as a migration oracle, then remove it
- Before deleting the helper, capture protocol fixtures from the existing implementation and one live Core session:
  - SOOD discovery response samples
  - successful `/info` + `/register` exchanges
  - browse/list/load responses for `browse`, `albums`, `artists`, and `search`
  - zone subscription snapshots and change messages
  - image fetch responses
  - action-list/playback flows
- Convert those captures into replay fixtures checked into tests.
- Once native parity is verified:
  - remove `HelperProcessController` from production use
  - remove `launch-helper.sh`
  - remove bundled helper resources and Node dependencies
  - keep only mock/test fixtures needed for offline verification

## Testing Plan
### A. Full coverage without a Roon Core
Implement as much protocol and state coverage as possible offline.

#### Unit tests
- `MooCodec`
  - parse valid request/continue/complete frames
  - reject malformed first lines, missing headers, bad lengths, invalid JSON
  - incremental parse across fragmented websocket messages
  - binary payload handling for image responses
- `SoodCodec` and discovery logic
  - encode query frames
  - decode multicast/broadcast SOOD responses
  - interface/broadcast address selection
  - dedupe and endpoint extraction by Core unique ID
- connection state machine
  - saved endpoint success
  - saved endpoint timeout then discovery fallback
  - manual connect failure
  - reconnect backoff
  - intentional disconnect vs accidental disconnect
  - duplicate discovered Core announcements
- registry/pairing logic
  - token reuse on reconnect
  - first-time authorization required
  - endpoint persistence after connect
  - handling of changed ports / changed Core metadata
- browse logic
  - hierarchy home/open/back/refresh/load
  - paged append behavior
  - prompt submission flow for search
  - action-list resolution
  - current-session playback action execution
  - replace/remove item events
- mapping logic
  - raw browse/zone/now-playing payloads into existing app models
  - tolerant decoding of numeric/string port edge cases if they can still occur on the wire
- image cache logic
  - image write/read path generation
  - cache key stability
  - error handling on missing/invalid image payloads

#### Replay tests
- Build a replay harness that feeds captured websocket MOO frames into the native client without a network.
- Use captured real transcripts as fixtures for:
  - connect/auth success
  - browse/list/load flows
  - zone subscribe snapshot + delta updates
  - playback action list and `Play Now`
  - disconnect/reconnect sequences
- Assert the native service emits the same `BridgeEventEnvelope` sequence the app expects.

#### Fake-Core local integration tests
- Add a test-only embedded fake Roon server.
- It should implement just enough of the protocol to simulate:
  - websocket `/api`
  - `/info` and `/register`
  - browse/list/load
  - transport subscription and controls
  - image fetch
  - error responses
- Add a fake discovery broadcaster that emits SOOD responses locally.
- Use these tests to validate the full `NativeRoonBridgeService` end to end without any live Core.
- If needed, add a test-only dependency such as `swift-nio` to host the fake websocket server deterministically; keep runtime code on Apple frameworks.

#### App-state and UI tests
- Reuse the existing bridge contract in tests so `AppModel` coverage stays high.
- Add `AppModel` tests for:
  - auto-connect startup flow
  - disconnected/no-Core behavior
  - search submission flow
  - browse pagination merge
  - zone merge behavior
  - current-session playback action dispatch
  - reconnect status transitions
- Add SwiftUI/UI tests using the mock/native fake service for:
  - no Core available
  - auto-connect timeout messaging
  - toolbar search behavior
  - browse result rendering
  - bottom mini-player state
  - menu commands and settings flow

### B. Live Core verification once available
Run a smaller live suite only for things offline tests cannot prove:
- discovery on a real network
- authorization/pairing behavior against an actual Core
- token reuse across app relaunches
- browse across real library hierarchies
- image fetch of real artwork
- zone subscription against real endpoints
- playback action execution (`Play Now`, `Add Next`, `Queue`, `Start Radio`)
- reconnect after Core restart or temporary network loss

### C. Acceptance criteria
The native implementation is complete only when:
- the app runs with no Node process, helper script, or JS resources in the execution path
- `AppModel` and the UI work through `NativeRoonBridgeService` with no feature regression versus the current helper-backed app
- offline tests cover protocol parsing, connection lifecycle, browse, transport, image, and state mapping comprehensively
- replay tests prove parity for captured real-world transcripts
- live Core tests pass for discovery, browse, zones, artwork, and playback actions

## Assumptions And Defaults
- The migration is a phased swap, not a one-shot architectural rewrite.
- Current app-facing bridge types remain the compatibility layer during the rewrite.
- Scope is current feature parity only; no new Roon features are added during the bridge replacement.
- Runtime implementation should use Apple frameworks by default; small test-only dependencies are allowed if they materially improve the fake-Core/replay harness.
- The mock bridge remains in the repo for UI development even after the JS helper is removed.
- The JS helper is retained temporarily only to generate oracle fixtures and compare native behavior during the migration, then removed.
