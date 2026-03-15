# Fixture Capture Plan

The native Swift rewrite should not start protocol work blind. The current helper should be used as an oracle to capture stable fixtures and replay transcripts.

## Capture Targets

### Discovery And Pairing

- saved-endpoint direct connect success
- saved-endpoint timeout and discovery fallback
- first-time authorization required
- persisted token reconnect success

### Browse

- top-level browse root
- library `albums`
- library `artists`
- service root for at least one subscribed service
- toolbar search flow
- `browse.openSearchMatch` flow for artist navigation
- `browse.openSearchMatch` flow for album navigation
- action-list resolution for:
  - album `Play Now`
  - track `Play Now`
  - at least one ellipsis action such as `Add Next`

### Transport And Queue

- zone subscription snapshot
- zone changed delta
- queue snapshot
- queue changed delta
- queue subscription handoff when switching zones
- queue on at least two real zones

### Image

- artwork fetch for now playing
- artwork fetch for browse grid/list content

## Capture Layers

### Layer 1: Bridge JSON

Capture the JSON line traffic between app and helper:

- outgoing request
- incoming response
- incoming event

This proves app-facing contract parity.

### Layer 2: Raw Roon-Oriented Payloads

Capture raw helper-side payloads for:

- discovery responses
- browse/list/load payloads
- transport zone payloads
- queue payloads
- image metadata responses

This proves protocol-mapping parity.

## Replay Requirements

The replay harness for the native Swift bridge should be able to:

- feed ordered request/response/event transcripts into the bridge layer
- feed raw protocol payloads into mapping and state machines
- assert emitted `BridgeEventEnvelope` sequences exactly
- assert stale-callback races do not regress

## Minimum Fixture Set Before Native Cutover

- one full connection transcript from launch to connected
- one search transcript
- one playback action transcript
- one queue transcript showing both snapshot and incremental change
- one multi-zone queue handoff transcript

Without that baseline, the Swift rewrite will be guessing at too much protocol behavior.
