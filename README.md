# Macaroon

Native macOS controller shell for a Roon Server, implemented as a SwiftUI app with a fully native Swift session stack.

## Structure

- `Package.swift`: Swift package manifest for the macOS app target and tests.
- `Sources/Macaroon`: SwiftUI app, native session/controller layer, protocol clients, and resources.
- `Tests/MacaroonTests`: native protocol, session, model, and UI-adjacent tests.

## Development

### Swift app

```bash
swift build
swift test
swift run Macaroon
```

### Standalone app bundle

```bash
./scripts/build_app_bundle.sh
```

This produces `builds/Macaroon.app`.
