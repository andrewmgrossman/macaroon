# Macaroon

Native macOS controller shell for a Roon Server, implemented as a SwiftUI app with a Node-based helper process.

## Structure

- `Package.swift`: Swift package manifest for the macOS app target and tests.
- `Sources/RoonControllerApp`: SwiftUI app, bridge client, models, and bundled helper resources.
- `Sources/RoonControllerApp/Resources/helper`: Node helper project that integrates with Roon's official JavaScript API.
- `Tests/RoonControllerTests`: Swift-side tests for bridge payload decoding.

## Development

### Swift app

```bash
swift build
swift test
swift run RoonControllerApp
```

### Helper

The helper requires Node.js plus the official Roon API packages:

```bash
cd Sources/RoonControllerApp/Resources/helper
npm install
npm test
```

If you want to run the app against a local Node runtime during development, set:

```bash
export ROON_HELPER_NODE="$(which node)"
```

## Current limitations

- The helper dependencies are not vendored; `npm install` is required before real Roon connectivity works.
- Artwork fetching is implemented on the helper side, but the SwiftUI layer currently renders placeholders instead of loading fetched image files.
- Packaging a private Node runtime inside a notarized `.app` bundle is not yet automated in this repo.
