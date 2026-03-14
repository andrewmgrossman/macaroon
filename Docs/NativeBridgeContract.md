# Native Bridge Contract

This document freezes the app-facing bridge contract that the current helper-backed implementation provides. The native Swift rewrite must preserve this surface first and only simplify it after parity is proven.

## App-Facing Seam

- `BridgeService`
  - `start()`
  - `stop()`
  - `send(_:params:)`
  - `request(_:params:as:)`
- `BridgeInboundMessage`
  - `.response`
  - `.event`
- `BridgeEventEnvelope`
  - `.connectionChanged`
  - `.authorizationRequired`
  - `.zonesSnapshot`
  - `.zonesChanged`
  - `.queueSnapshot`
  - `.queueChanged`
  - `.browseListChanged`
  - `.browseItemReplaced`
  - `.browseItemRemoved`
  - `.nowPlayingChanged`
  - `.persistRequested`
  - `.errorRaised`

## Commands In Use

These methods are consumed by `AppModel` today and are part of the compatibility contract for phase 1 of the Swift rewrite.

- `connect.auto`
  - params: `ConnectAutoParams`
  - behavior: try persisted endpoint/token first, then discovery fallback
- `connect.manual`
  - params: `ConnectManualParams`
- `core.disconnect`
  - params: `DisconnectParams`
- `zones.subscribe`
  - params: `ZonesSubscribeParams`
- `queue.subscribe`
  - params: `QueueSubscribeParams`
  - behavior: subscribes to queue for the selected zone/output
- `queue.playFromHere`
  - params: `QueuePlayFromHereParams`
- `browse.services`
  - params: `EmptyParams`
  - result: `BrowseServicesResult`
  - behavior: one-time startup fetch of subscribed browse services, filtered for sidebar use
- `browse.open`
  - params: `BrowseOpenParams`
- `browse.openService`
  - params: `BrowseOpenServiceParams`
  - behavior: open a service root from the top-level browse root
- `browse.back`
  - params: `BrowseBackParams`
- `browse.home`
  - params: `BrowseHomeParams`
- `browse.refresh`
  - params: `BrowseRefreshParams`
- `browse.loadPage`
  - params: `BrowseLoadPageParams`
  - behavior: sparse page loading for logical full-length lists
- `browse.submitInput`
  - params: `BrowseSubmitInputParams`
- `browse.contextActions`
  - params: `BrowseContextActionsParams`
  - result: `BrowseActionMenuResult`
- `browse.performAction`
  - params: `BrowsePerformActionParams`
  - behavior: resolve and execute in the current browse session, not in a detached synthetic session
- `browse.openSearchMatch`
  - params: `BrowseOpenSearchMatchParams`
  - behavior: helper-driven search navigation used by now-playing artist/album navigation
- `transport.command`
  - params: `TransportCommandParams`
- `transport.seek`
  - params: `TransportSeekParams`
- `transport.changeVolume`
  - params: `TransportVolumeParams`
- `transport.mute`
  - params: `TransportMuteParams`
- `image.fetch`
  - params: `ImageFetchParams`
  - result: `ImageFetchedResult`

## Events In Use

- `core.connectionChanged`
  - payload: `ConnectionChangedEvent`
- `core.authorizationRequired`
  - payload: `AuthorizationRequiredEvent`
- `zones.snapshot`
  - payload: `ZonesSnapshotEvent`
- `zones.changed`
  - payload: `ZonesChangedEvent`
- `queue.snapshot`
  - payload: `QueueSnapshotEvent`
- `queue.changed`
  - payload: `QueueChangedEvent`
- `browse.listChanged`
  - payload: `BrowseListChangedEvent`
- `browse.itemReplaced`
  - payload: `BrowseItemReplacedEvent`
- `browse.itemRemoved`
  - payload: `BrowseItemRemovedEvent`
- `nowPlaying.changed`
  - payload: `NowPlayingChangedEvent`
- `session.persistRequested`
  - payload: `PersistRequestedEvent`
- `error.raised`
  - payload: `ErrorRaisedEvent`

## Critical Behavioral Semantics

These are not obvious from the type signatures alone and must be preserved in the native implementation.

- Search is not a simple top-level `search` RPC.
  - The helper maps search flows onto `browse` with a dedicated `multi_session_key`.
  - The app relies on helper-driven `browse.openSearchMatch` for now-playing artist/album navigation.
- Browse service discovery is startup-only.
  - The sidebar service list is fetched once after a successful Core connection and reused for the rest of the session.
- Queue subscriptions are zone-sensitive and race-prone.
  - Stale queue subscription callbacks must not clear a newer active queue subscription.
- Zone switching must not refresh the main browse pane.
  - It should only change queue and playback targeting.
- Queue sidebar visibility must not mutate or refresh browse state.
  - It is a presentation concern only.
- Playback actions must execute in the current browse session.
  - Roon `item_key` values are session-scoped.
- App termination must tear down the bridge cleanly.
  - The current helper-backed app now explicitly shuts the helper down on quit.

## Native Rewrite Scope For Phase 1

The native Swift bridge is not complete until it can preserve:

- connection and authorization behavior
- zones and now-playing updates
- queue subscription and queue item activation
- search behavior, including current now-playing navigation helpers
- browse service sidebar behavior
- playback actions and transport controls
- artwork fetch and cache handoff
- session persistence and direct reconnect semantics
