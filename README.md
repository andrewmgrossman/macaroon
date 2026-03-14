# Macaroon

Native macOS controller shell for a Roon Server, implemented as a SwiftUI app with a native Swift bridge and an optional Node-based helper fallback.

## Structure

- `Package.swift`: Swift package manifest for the macOS app target and tests.
- `Sources/Macaroon`: SwiftUI app, bridge client, models, and bundled helper resources.
- `Sources/Macaroon/Resources/helper`: Node helper project that integrates with Roon's official JavaScript API.
- `Tests/MacaroonTests`: Swift-side tests for bridge payload decoding.

## Development

### Swift app

```bash
swift build
swift test
swift run Macaroon
```

### Helper

The helper requires Node.js plus the official Roon API packages:

```bash
cd Sources/Macaroon/Resources/helper
npm install
npm test
```

If you want to run the app against a local Node runtime during development, set:

```bash
export ROON_HELPER_NODE="$(which node)"
```

### Native bridge

The native Swift bridge is the default runtime path.

```bash
swift run Macaroon
```

To run the native bridge against the checked-in live replay fixture:

```bash
export MACAROON_NATIVE_REPLAY_FIXTURE="/Users/andrewmg/roox/Fixtures/Replay/live-core-session-001/bridge-lines.jsonl"
```

### Node helper fallback

To force the legacy Node-based bridge instead of the native bridge:

```bash
export MACAROON_USE_NODE_BRIDGE=1
swift run Macaroon
```

### Fixture capture

To capture current helper/Core traffic for replay fixtures:

```bash
export MACAROON_CAPTURE_FIXTURES=1
```

Or capture into a specific directory:

```bash
export MACAROON_CAPTURE_DIR="/path/to/fixtures"
```

Current capture outputs:

- `bridge-lines.jsonl`: app-to-helper JSON line traffic
- `helper-lines.jsonl`: helper request/response/event traffic

Checked-in replay fixtures:

- `Fixtures/Replay/live-core-session-001/bridge-lines.jsonl`
- `Fixtures/Replay/live-core-session-001/helper-lines.jsonl`

## Current limitations

- The helper dependencies are not vendored; `npm install` is required before real Roon connectivity works.
- Artwork fetching is implemented on the helper side, but the SwiftUI layer currently renders placeholders instead of loading fetched image files.
- Packaging a private Node runtime inside a notarized `.app` bundle is not yet automated in this repo.
