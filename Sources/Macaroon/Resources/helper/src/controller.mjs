import { createRequire } from "node:module";
import {
  mapConnectionStatus,
  saveArtwork,
  toBrowseItem,
  toBrowsePage,
  toCoreSummary,
  toQueueState,
  toZoneSummary
} from "./mappers.mjs";

const require = createRequire(import.meta.url);

const RoonApi = require("node-roon-api");
const RoonApiBrowse = require("node-roon-api-browse");
const RoonApiImage = require("node-roon-api-image");
const RoonApiTransport = require("node-roon-api-transport");

export class RoonBridgeController {
  constructor(output) {
    this.output = output;
    this.persistedState = { pairedCoreID: null, tokens: {}, endpoints: {} };
    this.core = null;
    this.coreLocation = { host: null, port: null };
    this.transportSubscription = null;
    this.queueSubscription = null;
    this.queueState = null;
    this.queueZoneOrOutputID = null;
    this.queueSubscriptionGeneration = 0;
    this.browseSessions = new Map();
    this.contextSessions = new Map();
    this.connectionMode = "idle";
    this.intentionalDisconnect = false;
    this.reconnectTimer = null;
    this.discoveryTimeout = null;
    this.directConnectTimeout = null;
    this.activeAttemptID = 0;
    this.activeMoo = null;
    this.activeConnectionAttemptID = 0;
    this.closeDisposition = null;
    this.reconnectBackoffMs = 2000;
    this.roon = this.#makeRoonApi();
    this.roon.init_services({
      required_services: [RoonApiBrowse, RoonApiTransport, RoonApiImage]
    });
  }

  shutdown() {
    this.#disconnect({ intentional: true, emitState: false });
  }

  #sessionContextForHierarchy(hierarchy) {
    if (hierarchy === "search") {
      return {
        requestHierarchy: "browse",
        multiSessionKey: "macaroon-search"
      };
    }

    return {
      requestHierarchy: hierarchy,
      multiSessionKey: null
    };
  }

  async handle(message) {
    switch (message.method) {
      case "connect.auto":
        this.persistedState = message.params.persistedState ?? this.persistedState;
        await this.#connectAutomatically();
        return {};
      case "connect.manual":
        this.persistedState = message.params.persistedState ?? this.persistedState;
        await this.#connectManually({
          host: message.params.host,
          port: message.params.port
        });
        return {};
      case "core.disconnect":
        this.#disconnect({ intentional: true, emitState: true });
        return {};
      case "zones.subscribe":
        this.#subscribeToZones();
        return {};
      case "queue.subscribe":
        this.#subscribeToQueue(message.params.zoneOrOutputID, message.params.maxItemCount);
        return {};
      case "queue.playFromHere":
        await this.#playFromQueue(message.params.zoneOrOutputID, message.params.queueItemID);
        return {};
      case "browse.services":
        return await this.#browseServices();
      case "browse.open":
        await this.#browse({
          hierarchy: message.params.hierarchy,
          zoneOrOutputID: message.params.zoneOrOutputID ?? null,
          itemKey: message.params.itemKey
        });
        return {};
      case "browse.openService":
        await this.#openBrowseService(message.params.title, message.params.zoneOrOutputID ?? null);
        return {};
      case "browse.back":
        await this.#browse({
          hierarchy: message.params.hierarchy,
          zoneOrOutputID: message.params.zoneOrOutputID ?? null,
          popLevels: message.params.levels
        });
        return {};
      case "browse.home":
        await this.#browse({
          hierarchy: message.params.hierarchy,
          zoneOrOutputID: message.params.zoneOrOutputID ?? null,
          popAll: true
        });
        return {};
      case "browse.refresh":
        await this.#browse({
          hierarchy: message.params.hierarchy,
          zoneOrOutputID: message.params.zoneOrOutputID ?? null,
          refreshList: true
        });
        return {};
      case "browse.loadPage":
        await this.#loadBrowsePage(
          message.params.hierarchy,
          message.params.offset,
          message.params.count
        );
        return {};
      case "browse.submitInput":
        await this.#browse({
          hierarchy: message.params.hierarchy,
          zoneOrOutputID: message.params.zoneOrOutputID ?? null,
          itemKey: message.params.itemKey,
          input: message.params.input
        });
        return {};
      case "browse.contextActions":
        return await this.#contextActions(message.params);
      case "browse.performAction":
        await this.#performContextAction(message.params);
        return {};
      case "browse.openSearchMatch":
        await this.#openSearchMatch(message.params);
        return {};
      case "transport.command":
        await this.#transport(message.params.zoneOrOutputID, message.params.command);
        return {};
      case "transport.seek":
        await this.#seek(message.params.zoneOrOutputID, message.params.how, message.params.seconds);
        return {};
      case "transport.changeVolume":
        await this.#changeVolume(message.params.outputID, message.params.how, message.params.value);
        return {};
      case "transport.mute":
        await this.#mute(message.params.outputID, message.params.how);
        return {};
      case "image.fetch":
        return await this.#fetchImage(message.params);
      default:
        throw new Error(`Unsupported method: ${message.method}`);
    }
  }

  emit(event, payload) {
    this.output.sendEvent(event, payload);
  }

  emitError(code, message) {
    this.emit("error.raised", { code, message });
  }

  #normalizePort(port) {
    if (typeof port === "number" && Number.isFinite(port)) {
      return port;
    }
    if (typeof port === "string" && port.trim().length > 0) {
      const parsed = Number.parseInt(port, 10);
      if (Number.isFinite(parsed)) {
        return parsed;
      }
    }
    return null;
  }

  async #connectAutomatically() {
    this.intentionalDisconnect = false;
    this.connectionMode = "auto";
    const attemptID = ++this.activeAttemptID;
    this.#clearRecoveryTimers();
    this.#disconnect({ intentional: false, emitState: false });

    const pairedCoreID = this.persistedState.pairedCoreID;
    const token = pairedCoreID ? this.persistedState.tokens?.[pairedCoreID] : null;
    const endpoint = pairedCoreID ? this.persistedState.endpoints?.[pairedCoreID] : null;

    if (pairedCoreID && token && endpoint) {
      this.emit("core.connectionChanged", {
        status: mapConnectionStatus("connecting", "saved server")
      });
      this.#connectDirect({
        host: endpoint.host,
        port: endpoint.port,
        attemptID
      });
      return;
    }

    this.#startDiscoveryFallback(attemptID);
  }

  async #connectManually({ host, port }) {
    this.intentionalDisconnect = false;
    this.connectionMode = "manual";
    const attemptID = ++this.activeAttemptID;
    this.#clearRecoveryTimers();
    this.#disconnect({ intentional: false, emitState: false });

    this.coreLocation = { host, port };
    this.emit("core.connectionChanged", {
      status: mapConnectionStatus("manual")
    });

    const moo = this.roon.ws_connect({
      host,
      port,
      onclose: () => this.#handleConnectionClosed(attemptID),
      onerror: () => {
        if (this.activeAttemptID !== attemptID) {
          return;
        }
        this.emitError("core.manual_connect_failed", "Manual websocket connection to the Roon Core failed.");
      }
    });
    this.activeMoo = moo;
  }

  #connectDirect({ host, port, attemptID }) {
    const normalizedPort = this.#normalizePort(port);
    this.coreLocation = { host, port: normalizedPort ?? port };
    const moo = this.roon.ws_connect({
      host,
      port: normalizedPort ?? port,
      onclose: () => this.#handleConnectionClosed(attemptID)
    });
    this.activeMoo = moo;
    this.activeConnectionAttemptID = attemptID;

    this.directConnectTimeout = setTimeout(() => {
      if (this.activeAttemptID !== attemptID) {
        return;
      }
      if (this.core?.core_id === this.persistedState.pairedCoreID) {
        return;
      }
      this.closeDisposition = { attemptID, action: "fallbackDiscovery" };
      try {
        moo.transport?.close?.();
      } catch {
        this.closeDisposition = null;
        this.#startDiscoveryFallback(attemptID);
      }
    }, 8000);
  }

  #startDiscoveryFallback(attemptID) {
    if (this.activeAttemptID !== attemptID) {
      return;
    }

    this.connectionMode = "discovery";
    this.emit("core.connectionChanged", {
      status: mapConnectionStatus("connecting")
    });
    this.roon.start_discovery();

    this.discoveryTimeout = setTimeout(() => {
      if (this.activeAttemptID !== attemptID || this.core) {
        return;
      }
      this.emitError(
        "core.discovery_timeout",
        "No Roon Core was resolved automatically. Open Server Settings if discovery cannot find the correct Core."
      );
    }, 12000);
  }

  #disconnect({ intentional, emitState }) {
    this.intentionalDisconnect = intentional;
    this.#clearRecoveryTimers();
    this.roon.stop_discovery?.();
    this.roon.disconnect_all?.();
    this.#closeActiveMoo("ignore");
    this.transportSubscription = null;
    this.#clearQueueSubscription();
    this.core = null;
    if (emitState) {
      this.emit("core.connectionChanged", {
        status: mapConnectionStatus("disconnected")
      });
    }
  }

  #clearRecoveryTimers() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.discoveryTimeout) {
      clearTimeout(this.discoveryTimeout);
      this.discoveryTimeout = null;
    }
    if (this.directConnectTimeout) {
      clearTimeout(this.directConnectTimeout);
      this.directConnectTimeout = null;
    }
  }

  #closeActiveMoo(action = "ignore") {
    const moo = this.activeMoo;
    const attemptID = this.activeConnectionAttemptID;
    this.activeMoo = null;
    this.activeConnectionAttemptID = 0;

    if (!moo) {
      return;
    }

    this.closeDisposition = { attemptID, action };
    try {
      moo.transport?.close?.();
    } catch {
      this.closeDisposition = null;
    }
  }

  #handleConnectionClosed(attemptID) {
    if (this.activeAttemptID !== attemptID) {
      return;
    }
    const closeDisposition = this.closeDisposition?.attemptID === attemptID ? this.closeDisposition : null;
    this.closeDisposition = null;
    this.transportSubscription = null;
    this.queueSubscription = null;
    this.queueState = null;
    this.queueZoneOrOutputID = null;
    this.activeMoo = null;
    this.activeConnectionAttemptID = 0;
    this.core = null;

    if (closeDisposition?.action === "ignore") {
      return;
    }

    if (closeDisposition?.action === "fallbackDiscovery") {
      this.#clearRecoveryTimers();
      this.#startDiscoveryFallback(attemptID);
      return;
    }

    if (this.intentionalDisconnect) {
      this.emit("core.connectionChanged", {
        status: mapConnectionStatus("disconnected")
      });
      return;
    }

    this.emit("core.connectionChanged", {
      status: mapConnectionStatus("connecting", "reconnecting")
    });

    this.reconnectTimer = setTimeout(() => {
      if (this.connectionMode === "manual" && this.coreLocation.host && this.coreLocation.port) {
        this.#connectManually(this.coreLocation);
        return;
      }
      this.#connectAutomatically();
    }, this.reconnectBackoffMs);
    this.reconnectBackoffMs = Math.min(this.reconnectBackoffMs * 2, 30000);
  }

  #makeRoonApi() {
    return new RoonApi({
      extension_id: "com.andrewmg.macaroon",
      display_name: "Macaroon",
      display_version: "0.1.0",
      publisher: "Andrew McG",
      email: "andrew@example.com",
      website: "https://example.invalid/macaroon",
      log_level: "none",
      get_persisted_state: () => ({
        paired_core_id: this.persistedState.pairedCoreID,
        tokens: this.persistedState.tokens
      }),
      set_persisted_state: (state) => {
        const rawEndpoints = state.endpoints ?? this.persistedState.endpoints ?? {};
        const endpoints = Object.fromEntries(
          Object.entries(rawEndpoints).map(([coreID, endpoint]) => [
            coreID,
            {
              host: endpoint.host,
              port: this.#normalizePort(endpoint.port) ?? endpoint.port
            }
          ])
        );
        this.persistedState = {
          pairedCoreID: state.paired_core_id ?? null,
          tokens: state.tokens ?? {},
          endpoints
        };
        this.emit("session.persistRequested", {
          persistedState: this.persistedState
        });
      },
      core_paired: (core) => {
        this.core = core;
        this.activeMoo = core.moo;
        this.activeConnectionAttemptID = this.activeAttemptID;
        this.closeDisposition = null;
        this.#clearRecoveryTimers();
        this.reconnectBackoffMs = 2000;
        this.roon.stop_discovery?.();
        this.#persistEndpointForCore(core);
        const summary = toCoreSummary(
          core,
          this.coreLocation.host,
          this.coreLocation.port
        );
        this.emit("core.connectionChanged", {
          status: mapConnectionStatus("connected", summary)
        });
      },
      core_unpaired: () => {
        if (!this.activeMoo && !this.core) {
          return;
        }
        this.#handleConnectionClosed(this.activeAttemptID);
      },
      moo_onerror: () => {
        if (this.intentionalDisconnect === false) {
          this.emitError("core.transport_error", "The connection to the Roon Core reported a transport error.");
        }
      }
    });
  }

  #persistEndpointForCore(core) {
    const host =
      core?.moo?.transport?.host ??
      core?.registration?.extension_host ??
      this.coreLocation.host;
    const port = this.#normalizePort(
      core?.moo?.transport?.port ??
        core?.registration?.http_port ??
        this.coreLocation.port
    );

    if (!host || !port) {
      return;
    }

    this.coreLocation = { host, port };
    const nextEndpoints = {
      ...(this.persistedState.endpoints ?? {}),
      [core.core_id]: { host, port }
    };
    this.persistedState = {
      pairedCoreID: core.core_id,
      tokens: this.persistedState.tokens ?? {},
      endpoints: nextEndpoints
    };
    this.emit("session.persistRequested", {
      persistedState: this.persistedState
    });
  }

  #ensureCore() {
    if (!this.core) {
      throw new Error("No paired Roon Core is available.");
    }
    return this.core;
  }

  #subscribeToZones() {
    const core = this.#ensureCore();
    const transport = core.services.RoonApiTransport;

    if (this.transportSubscription?.unsubscribe) {
      this.transportSubscription.unsubscribe(() => {});
    }

    this.transportSubscription = transport.subscribe_zones((response, message) => {
      if (response === "Subscribed") {
        this.emit("zones.snapshot", {
          zones: (message.zones ?? []).map(toZoneSummary)
        });
        for (const zone of message.zones ?? []) {
          this.emit("nowPlaying.changed", {
            zoneID: zone.zone_id,
            nowPlaying: toZoneSummary(zone).nowPlaying
          });
        }
        return;
      }

      if (response === "Changed") {
        const changes = [
          ...(message.zones_added ?? []),
          ...(message.zones_changed ?? [])
        ];
        this.emit("zones.changed", {
          zones: changes.map(toZoneSummary)
        });
        for (const zone of changes) {
          this.emit("nowPlaying.changed", {
            zoneID: zone.zone_id,
            nowPlaying: toZoneSummary(zone).nowPlaying
          });
        }
      }
    });
  }

  #subscribeToQueue(zoneOrOutputID, maxItemCount = 300) {
    const core = this.#ensureCore();
    const transport = core.services.RoonApiTransport;

    this.#clearQueueSubscription();
    this.queueZoneOrOutputID = zoneOrOutputID;
    const generation = this.queueSubscriptionGeneration;

    this.queueSubscription = transport.subscribe_queue(zoneOrOutputID, maxItemCount, (response, message) => {
      if (generation !== this.queueSubscriptionGeneration) {
        return;
      }

      if (response === "Subscribed") {
        this.queueState = toQueueState(message ?? {}, zoneOrOutputID, null);
        this.emit("queue.snapshot", {
          queue: this.queueState
        });
        return;
      }

      if (response === "Changed") {
        this.queueState = toQueueState(message ?? {}, zoneOrOutputID, this.queueState);
        this.emit("queue.changed", {
          queue: this.queueState
        });
        return;
      }

      if (response === "Unsubscribed") {
        this.#clearQueueSubscription();
        this.emit("queue.snapshot", {
          queue: null
        });
      }
    });
  }

  #clearQueueSubscription() {
    this.queueSubscriptionGeneration += 1;
    if (this.queueSubscription?.unsubscribe) {
      this.queueSubscription.unsubscribe(() => {});
    }
    this.queueSubscription = null;
    this.queueState = null;
    this.queueZoneOrOutputID = null;
  }

  async #browse({ hierarchy, zoneOrOutputID, itemKey = undefined, input = undefined, popAll = false, popLevels = undefined, refreshList = false }) {
    const sessionContext = this.#sessionContextForHierarchy(hierarchy);
    const options = {
      hierarchy: sessionContext.requestHierarchy,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      item_key: itemKey,
      input,
      pop_all: popAll || undefined,
      pop_levels: popLevels,
      refresh_list: refreshList || undefined
    };
    if (sessionContext.multiSessionKey) {
      options.multi_session_key = sessionContext.multiSessionKey;
    }

    const result = await this.#browseRequest(options);

    if (result.action === "message") {
      this.emitError(result.is_error ? "browse.error" : "browse.message", result.message);
      return;
    }

    if (result.action === "replace_item") {
      this.emit("browse.itemReplaced", {
        hierarchy,
        item: toBrowseItem(result.item)
      });
      if (input !== undefined) {
        await this.#refreshCurrentBrowseList(hierarchy);
      }
      return;
    }

    if (result.action === "remove_item") {
      this.emit("browse.itemRemoved", {
        hierarchy,
        itemKey
      });
      if (input !== undefined) {
        await this.#refreshCurrentBrowseList(hierarchy);
      }
      return;
    }

    if (result.action === "list") {
      const offset = Math.max(result.list.display_offset ?? 0, 0);
      this.browseSessions.set(hierarchy, {
        list: result.list,
        selectedZoneID: zoneOrOutputID ?? null,
        requestHierarchy: sessionContext.requestHierarchy,
        multiSessionKey: sessionContext.multiSessionKey
      });
      await this.#loadBrowsePage(hierarchy, offset, 100);
      return;
    }

    if (input !== undefined && result.action === "none") {
      await this.#refreshCurrentBrowseList(hierarchy);
    }
  }

  async #browseServices() {
    const sessionKey = "macaroon-sidebar-services";
    const items = await this.#loadBrowseRootItems({
      hierarchy: "browse",
      zoneOrOutputID: null,
      multiSessionKey: sessionKey
    });

    return {
      services: this.#serviceItemsFromBrowseRoot(items).map((item) => ({
        title: item.title
      }))
    };
  }

  async #loadBrowsePage(hierarchy, offset = 0, count = 100) {
    const state = this.browseSessions.get(hierarchy);
    const sessionContext = this.#sessionContextForHierarchy(hierarchy);

    const result = await this.#loadRequest({
      hierarchy: state?.requestHierarchy ?? sessionContext.requestHierarchy,
      offset,
      count,
      set_display_offset: offset,
      ...(state?.multiSessionKey ?? sessionContext.multiSessionKey
        ? { multi_session_key: state?.multiSessionKey ?? sessionContext.multiSessionKey }
        : {})
    });

    const list = result.list ?? state?.list;
    this.browseSessions.set(hierarchy, {
      list,
      selectedZoneID: state?.selectedZoneID ?? null,
      requestHierarchy: state?.requestHierarchy ?? sessionContext.requestHierarchy,
      multiSessionKey: state?.multiSessionKey ?? sessionContext.multiSessionKey
    });

    this.emit("browse.listChanged", {
      page: toBrowsePage({
        hierarchy,
        list,
        items: result.items ?? [],
        offset: result.offset ?? offset,
        selectedZoneID: state?.selectedZoneID ?? null
      })
    });
  }

  async #refreshCurrentBrowseList(hierarchy) {
    const state = this.browseSessions.get(hierarchy);
    if (!state?.list) {
      return;
    }

    const offset = Math.max(state.list.display_offset ?? 0, 0);
    await this.#loadBrowsePage(hierarchy, offset, 100);
  }

  async #openBrowseService(title, zoneOrOutputID) {
    const rootItems = await this.#loadBrowseRootItems({
      hierarchy: "browse",
      zoneOrOutputID,
      multiSessionKey: null
    });

    const serviceItem = rootItems.find((item) =>
      item?.item_key &&
      typeof item.title === "string" &&
      item.title.localeCompare(title, undefined, { sensitivity: "accent" }) === 0
    );
    if (!serviceItem?.item_key) {
      throw new Error(`Browse service '${title}' was not found.`);
    }

    const result = await this.#browseRequest({
      hierarchy: "browse",
      zone_or_output_id: zoneOrOutputID ?? undefined,
      item_key: serviceItem.item_key
    });

    await this.#activateBrowseResult({
      hierarchy: "browse",
      result,
      zoneOrOutputID,
      requestHierarchy: "browse",
      multiSessionKey: null
    });
  }

  async #openSearchMatch({ query, categoryTitle, matchTitle, zoneOrOutputID }) {
    const sessionContext = this.#sessionContextForHierarchy("search");
    const rootItems = await this.#loadBrowseRootItems({
      hierarchy: sessionContext.requestHierarchy,
      zoneOrOutputID,
      multiSessionKey: sessionContext.multiSessionKey
    });

    const libraryItem = rootItems.find((item) =>
      item?.item_key &&
      typeof item.title === "string" &&
      item.title.localeCompare("Library", undefined, { sensitivity: "accent" }) === 0
    );
    if (!libraryItem?.item_key) {
      throw new Error("Library search entry was not available.");
    }

    await this.#browseRequest({
      hierarchy: sessionContext.requestHierarchy,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      item_key: libraryItem.item_key,
      multi_session_key: sessionContext.multiSessionKey
    });

    const promptPage = await this.#loadCurrentSessionItems({
      hierarchy: sessionContext.requestHierarchy,
      multiSessionKey: sessionContext.multiSessionKey
    });
    const promptItem = (promptPage.items ?? []).find((item) => item?.input_prompt?.prompt);
    if (!promptItem?.item_key) {
      throw new Error("Search prompt was not available.");
    }

    await this.#browseRequest({
      hierarchy: sessionContext.requestHierarchy,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      item_key: promptItem.item_key,
      input: query,
      multi_session_key: sessionContext.multiSessionKey
    });

    const resultsPage = await this.#loadCurrentSessionItems({
      hierarchy: sessionContext.requestHierarchy,
      multiSessionKey: sessionContext.multiSessionKey
    });
    const categoryItem = (resultsPage.items ?? []).find((item) =>
      item?.item_key &&
      typeof item.title === "string" &&
      item.title.localeCompare(categoryTitle, undefined, { sensitivity: "accent" }) === 0
    );
    if (!categoryItem?.item_key) {
      throw new Error(`Search category '${categoryTitle}' was not available.`);
    }

    await this.#browseRequest({
      hierarchy: sessionContext.requestHierarchy,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      item_key: categoryItem.item_key,
      multi_session_key: sessionContext.multiSessionKey
    });

    const categoryPage = await this.#loadCurrentSessionItems({
      hierarchy: sessionContext.requestHierarchy,
      multiSessionKey: sessionContext.multiSessionKey
    });
    const matchedItem =
      (categoryPage.items ?? []).find((item) =>
        item?.item_key &&
        typeof item.title === "string" &&
        item.title.localeCompare(matchTitle, undefined, { sensitivity: "accent" }) === 0
      ) ??
      (categoryPage.items ?? []).find((item) => item?.item_key);

    if (!matchedItem?.item_key) {
      throw new Error(`No search result was available for '${matchTitle}'.`);
    }

    let result = await this.#browseRequest({
      hierarchy: sessionContext.requestHierarchy,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      item_key: matchedItem.item_key,
      multi_session_key: sessionContext.multiSessionKey
    });

    if (categoryTitle.localeCompare("Albums", undefined, { sensitivity: "accent" }) === 0) {
      const drilledItem = await this.#singleExactMatchItem({
        hierarchy: sessionContext.requestHierarchy,
        multiSessionKey: sessionContext.multiSessionKey,
        matchTitle
      });
      if (drilledItem?.item_key) {
        result = await this.#browseRequest({
          hierarchy: sessionContext.requestHierarchy,
          zone_or_output_id: zoneOrOutputID ?? undefined,
          item_key: drilledItem.item_key,
          multi_session_key: sessionContext.multiSessionKey
        });
      }
    }

    await this.#activateBrowseResult({
      hierarchy: "search",
      result,
      zoneOrOutputID,
      requestHierarchy: sessionContext.requestHierarchy,
      multiSessionKey: sessionContext.multiSessionKey
    });
  }

  async #transport(zoneOrOutputID, command) {
    const core = this.#ensureCore();
    const transport = core.services.RoonApiTransport;

    await new Promise((resolve, reject) => {
      transport.control(zoneOrOutputID, command, (error) => {
        if (error) {
          reject(new Error(error));
          return;
        }
        resolve();
      });
    });
  }

  async #seek(zoneOrOutputID, how, seconds) {
    const core = this.#ensureCore();
    const transport = core.services.RoonApiTransport;

    await new Promise((resolve, reject) => {
      transport.seek(zoneOrOutputID, how, seconds, (error) => {
        if (error) {
          reject(new Error(error));
          return;
        }
        resolve();
      });
    });
  }

  async #changeVolume(outputID, how, value) {
    const core = this.#ensureCore();
    const transport = core.services.RoonApiTransport;

    await new Promise((resolve, reject) => {
      transport.change_volume(outputID, how, value, (error) => {
        if (error) {
          reject(new Error(error));
          return;
        }
        resolve();
      });
    });
  }

  async #mute(outputID, how) {
    const core = this.#ensureCore();
    const transport = core.services.RoonApiTransport;

    await new Promise((resolve, reject) => {
      transport.mute(outputID, how, (error) => {
        if (error) {
          reject(new Error(error));
          return;
        }
        resolve();
      });
    });
  }

  async #fetchImage(params) {
    const core = this.#ensureCore();
    const imageService = core.services.RoonApiImage;

    const { imageKey, width, height, format } = params;
    const image = await new Promise((resolve, reject) => {
      imageService.get_image(
        imageKey,
        {
          scale: "fit",
          width,
          height,
          format
        },
        (error, contentType, data) => {
          if (error) {
            reject(new Error(error));
            return;
          }
          resolve({
            contentType,
            data
          });
        }
      );
    });

    const extension = image.contentType === "image/png" ? "png" : "jpg";
    const localURL = await saveArtwork(imageKey, image.data, extension);
    return {
      imageKey,
      localURL
    };
  }

  async #playFromQueue(zoneOrOutputID, queueItemID) {
    const core = this.#ensureCore();
    const transport = core.services.RoonApiTransport;

    await new Promise((resolve, reject) => {
      transport.play_from_here(zoneOrOutputID, queueItemID, (message) => {
        if (message && message.name && message.name !== "Success") {
          reject(new Error(message.name));
          return;
        }
        resolve();
      });
    });
  }

  async #contextActions({ hierarchy, itemKey, zoneOrOutputID }) {
    const sessionContext = this.#sessionContextForHierarchy(hierarchy);
    const { title, actions, popLevels } = await this.#resolveActionsInCurrentSession({
      hierarchy,
      itemKey,
      zoneOrOutputID
    });

    try {
      return {
        sessionKey: `${hierarchy}:${itemKey}`,
        title,
        actions: actions.map(toBrowseItem)
      };
    } finally {
      if (popLevels > 0) {
        try {
          await this.#browseRequest({
            hierarchy: sessionContext.requestHierarchy,
            pop_levels: popLevels,
            ...(sessionContext.multiSessionKey ? { multi_session_key: sessionContext.multiSessionKey } : {})
          });
        } catch {
          // Ignore menu-cleanup failures. The user only needs the resolved actions.
        }
      }
    }
  }

  async #performContextAction({ hierarchy, sessionKey, itemKey, zoneOrOutputID, contextItemKey, actionTitle }) {
    if (contextItemKey && actionTitle) {
      await this.#performResolvedContextAction({
        hierarchy,
        contextItemKey,
        actionTitle,
        zoneOrOutputID
      });
      return;
    }

    await this.#browseRequest({
      hierarchy: sessionContext.requestHierarchy,
      item_key: itemKey,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      ...(sessionContext.multiSessionKey ? { multi_session_key: sessionContext.multiSessionKey } : {})
    });
  }

  async #browseRequest(options) {
    const core = this.#ensureCore();
    const browse = core.services.RoonApiBrowse;

    return await new Promise((resolve, reject) => {
      browse.browse(options, (error, response) => {
        if (error) {
          reject(new Error(error));
          return;
        }
        resolve(response);
      });
    });
  }

  async #loadRequest(options) {
    const core = this.#ensureCore();
    const browse = core.services.RoonApiBrowse;

    return await new Promise((resolve, reject) => {
      browse.load(options, (error, response) => {
        if (error) {
          reject(new Error(error));
          return;
        }
        resolve(response);
      });
    });
  }

  async #loadBrowseRootItems({ hierarchy, zoneOrOutputID, multiSessionKey }) {
    await this.#browseRequest({
      hierarchy,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      pop_all: true,
      ...(multiSessionKey ? { multi_session_key: multiSessionKey } : {})
    });

    const loaded = await this.#loadRequest({
      hierarchy,
      offset: 0,
      count: 100,
      set_display_offset: 0,
      ...(multiSessionKey ? { multi_session_key: multiSessionKey } : {})
    });

    return loaded.items ?? [];
  }

  async #loadCurrentSessionItems({ hierarchy, multiSessionKey }) {
    const loaded = await this.#loadRequest({
      hierarchy,
      offset: 0,
      count: 100,
      set_display_offset: 0,
      ...(multiSessionKey ? { multi_session_key: multiSessionKey } : {})
    });

    return {
      list: loaded.list ?? null,
      items: loaded.items ?? []
    };
  }

  async #singleExactMatchItem({ hierarchy, multiSessionKey, matchTitle }) {
    const page = await this.#loadCurrentSessionItems({ hierarchy, multiSessionKey });
    const candidates = (page.items ?? []).filter((item) => item?.item_key);
    if (candidates.length !== 1) {
      return null;
    }

    const candidate = candidates[0];
    if (typeof candidate.title !== "string") {
      return null;
    }

    if (candidate.title.localeCompare(matchTitle, undefined, { sensitivity: "accent" }) !== 0) {
      return null;
    }

    return candidate;
  }

  async #activateBrowseResult({ hierarchy, result, zoneOrOutputID, requestHierarchy, multiSessionKey }) {
    if (result.action === "message") {
      throw new Error(result.message ?? "Browse request failed.");
    }

    if (result.action !== "list") {
      throw new Error("Browse request did not produce a list.");
    }

    const offset = Math.max(result.list?.display_offset ?? 0, 0);
    this.browseSessions.set(hierarchy, {
      list: result.list,
      selectedZoneID: zoneOrOutputID ?? null,
      requestHierarchy,
      multiSessionKey
    });
    await this.#loadBrowsePage(hierarchy, offset, 100);
  }

  async #resolveListForSession({ hierarchy, sessionKey, result, zoneOrOutputID }) {
    const sessionContext = this.#sessionContextForHierarchy(hierarchy);
    if (result.action === "message") {
      throw new Error(result.message);
    }

    if (result.action !== "list") {
      throw new Error("Browse request did not return a list.");
    }

    const offset = Math.max(result.list.display_offset ?? 0, 0);
    const loadOptions = {
      hierarchy: sessionContext.requestHierarchy,
      offset,
      count: 100,
      set_display_offset: offset
    };
    if (sessionKey) {
      loadOptions.multi_session_key = sessionKey;
    } else if (sessionContext.multiSessionKey) {
      loadOptions.multi_session_key = sessionContext.multiSessionKey;
    }

    const loaded = await this.#loadRequest(loadOptions);

    return {
      list: loaded.list ?? result.list,
      items: loaded.items ?? [],
      selectedZoneID: zoneOrOutputID ?? null
    };
  }

  async #resolveActionsInCurrentSession({ hierarchy, itemKey, zoneOrOutputID }) {
    const sessionContext = this.#sessionContextForHierarchy(hierarchy);
    const baselineLevel = this.browseSessions.get(hierarchy)?.list?.level ?? 0;

    const topLevelResult = await this.#browseRequest({
      hierarchy: sessionContext.requestHierarchy,
      item_key: itemKey,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      ...(sessionContext.multiSessionKey ? { multi_session_key: sessionContext.multiSessionKey } : {})
    });

    const topLevelList = await this.#resolveListForSession({
      hierarchy,
      sessionKey: null,
      result: topLevelResult,
      zoneOrOutputID
    });

    if (topLevelList.list.hint === "action_list") {
      return {
        title: topLevelList.list.title,
        actions: topLevelList.items,
        popLevels: Math.max((topLevelList.list.level ?? baselineLevel) - baselineLevel, 0)
      };
    }

    const actionListItem = topLevelList.items.find((item) => item.hint === "action_list");
    if (!actionListItem?.item_key) {
      throw new Error("No action list available for the selected item.");
    }

    const actionsResult = await this.#browseRequest({
      hierarchy: sessionContext.requestHierarchy,
      item_key: actionListItem.item_key,
      zone_or_output_id: zoneOrOutputID ?? undefined,
      ...(sessionContext.multiSessionKey ? { multi_session_key: sessionContext.multiSessionKey } : {})
    });

    const actionsList = await this.#resolveListForSession({
      hierarchy,
      sessionKey: null,
      result: actionsResult,
      zoneOrOutputID
    });

    return {
      title: actionsList.list.title,
      actions: actionsList.items,
      popLevels: Math.max((actionsList.list.level ?? baselineLevel) - baselineLevel, 0)
    };
  }

  async #performResolvedContextAction({ hierarchy, contextItemKey, actionTitle, zoneOrOutputID }) {
    const sessionContext = this.#sessionContextForHierarchy(hierarchy);
    const resolved = await this.#resolveActionsInCurrentSession({
      hierarchy,
      itemKey: contextItemKey,
      zoneOrOutputID
    });

    let actionError = null;
    try {
      const action = resolved.actions.find((candidate) =>
        candidate.title?.localeCompare(actionTitle, undefined, { sensitivity: "accent" }) === 0
      );

      if (!action?.item_key) {
        throw new Error(`The action "${actionTitle}" is no longer available for this item.`);
      }

      await this.#browseRequest({
        hierarchy: sessionContext.requestHierarchy,
        item_key: action.item_key,
        zone_or_output_id: zoneOrOutputID ?? undefined,
        ...(sessionContext.multiSessionKey ? { multi_session_key: sessionContext.multiSessionKey } : {})
      });
    } catch (error) {
      actionError = error;
      throw error;
    } finally {
      if (resolved.popLevels > 0) {
        try {
          await this.#browseRequest({
            hierarchy: sessionContext.requestHierarchy,
            pop_levels: resolved.popLevels,
            ...(sessionContext.multiSessionKey ? { multi_session_key: sessionContext.multiSessionKey } : {})
          });
        } catch (cleanupError) {
          if (actionError) {
            this.emitError("browse.action_cleanup_failed", cleanupError.message);
          }
        }
      }
    }
  }

  #serviceItemsFromBrowseRoot(items) {
    const excludedTitles = new Set([
      "albums",
      "artists",
      "composers",
      "genres",
      "internet radio",
      "library",
      "my live radio",
      "playlists",
      "settings"
    ]);

    return items
      .filter((item) => item?.item_key && typeof item.title === "string")
      .filter((item) => excludedTitles.has(item.title.trim().toLowerCase()) === false)
      .sort((left, right) => left.title.localeCompare(right.title, undefined, { sensitivity: "base" }));
  }
}
