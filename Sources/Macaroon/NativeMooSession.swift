import Foundation

actor NativeMooSession {
    private let transportFactory: @Sendable () -> any NativeMooTransportProtocol
    private var transport: (any NativeMooTransportProtocol)?
    private var nextRequestID = 0
    private var pendingRequests: [String: CheckedContinuation<MooMessageEnvelope, Error>] = [:]
    private var subscriptionHandlers: [String: @Sendable (MooMessageEnvelope) -> Void] = [:]
    private var bufferedMessages: [String: [MooMessageEnvelope]] = [:]
    private var receiveLoopTask: Task<Void, Never>?
    private var currentPairedCoreID: String?
    private var currentCoreID: String?

    init(
        transportFactory: @escaping @Sendable () -> any NativeMooTransportProtocol,
        currentPairedCoreID: String?
    ) {
        self.transportFactory = transportFactory
        self.currentPairedCoreID = currentPairedCoreID
    }

    func connect(to endpoint: RoonCoreEndpoint) async throws {
        await disconnect()

        let transport = transportFactory()
        self.transport = transport
        MacaroonDebugLogger.logProtocol(
            "session.connect",
            details: [
                "host": endpoint.host,
                "port": String(endpoint.port)
            ]
        )
        try await transport.connect(to: endpoint)

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() async {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        MacaroonDebugLogger.logProtocol("session.disconnect")

        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        continuations.forEach { $0.resume(throwing: BridgeRuntimeError.processUnavailable) }
        subscriptionHandlers.removeAll()

        await transport?.disconnect()
        transport = nil
    }

    func setCurrentCoreID(_ coreID: String?) {
        currentCoreID = coreID
    }

    func setCurrentPairedCoreID(_ coreID: String?) {
        currentPairedCoreID = coreID
    }

    func request<Body: Encodable>(_ name: String, body: Body?) async throws -> MooMessageEnvelope {
        guard let transport else {
            throw BridgeRuntimeError.processUnavailable
        }

        let requestID = nextRequestIdentifier()
        let payload = try encodeRequestPayload(name: name, body: body, requestID: requestID)
        MacaroonDebugLogger.logProtocolData(direction: "outbound", label: "moo.request", data: payload)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            Task {
                do {
                    try await transport.send(payload)
                    await self.flushBufferedMessages(for: requestID)
                } catch {
                    let continuation = self.pendingRequests.removeValue(forKey: requestID)
                    continuation?.resume(throwing: error)
                }
            }
        }
    }

    func subscribe<Body: Encodable>(
        _ name: String,
        body: Body?,
        handler: @escaping @Sendable (MooMessageEnvelope) -> Void
    ) async throws {
        guard let transport else {
            throw BridgeRuntimeError.processUnavailable
        }

        let requestID = nextRequestIdentifier()
        subscriptionHandlers[requestID] = handler
        let payload = try encodeRequestPayload(name: name, body: body, requestID: requestID)
        MacaroonDebugLogger.logProtocolData(direction: "outbound", label: "moo.subscribe", data: payload)
        try await transport.send(payload)
        await flushBufferedMessages(for: requestID)
    }

    private func receiveLoop() async {
        while Task.isCancelled == false {
            do {
                guard let transport else {
                    return
                }

                let message = try MooCodec.decodeMessage(try await transport.receive())
                MacaroonDebugLogger.logProtocolMessage(direction: "inbound", envelope: message)
                try await dispatch(message)
            } catch {
                MacaroonDebugLogger.logError("session.receive_loop_failed", error: error)
                let continuations = pendingRequests.values
                pendingRequests.removeAll()
                continuations.forEach { $0.resume(throwing: error) }
                return
            }
        }
    }

    private func dispatch(_ message: MooMessageEnvelope) async throws {
        guard let requestID = message.requestID else {
            return
        }

        switch message.verb {
        case .request:
            try await handleInboundRequest(message)
        case .continue, .complete:
            if let handler = subscriptionHandlers[requestID] {
                handler(message)
                if message.verb == .complete {
                    subscriptionHandlers.removeValue(forKey: requestID)
                }
                return
            }

            guard let continuation = pendingRequests.removeValue(forKey: requestID) else {
                bufferedMessages[requestID, default: []].append(message)
                return
            }
            continuation.resume(returning: message)
        }
    }

    private func handleInboundRequest(_ message: MooMessageEnvelope) async throws {
        guard let transport,
              let requestID = message.requestID
        else {
            return
        }

        switch (message.service, message.name) {
        case ("com.roonlabs.ping:1", "com.roonlabs.ping:1/ping"):
            try await transport.send(try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: requestID,
                body: nil,
                contentType: nil
            ))
        case ("com.roonlabs.pairing:1", "com.roonlabs.pairing:1/get_pairing"):
            try await transport.send(try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: requestID,
                body: try JSONEncoder().encode(NativePairingStatePayload(paired_core_id: currentPairedCoreID)),
                contentType: "application/json"
            ))
        case ("com.roonlabs.pairing:1", "com.roonlabs.pairing:1/subscribe_pairing"):
            subscriptionHandlers[requestID] = { _ in }
            try await transport.send(try MooCodec.encodeMessage(
                verb: .continue,
                name: "Subscribed",
                requestID: requestID,
                body: try JSONEncoder().encode(NativePairingStatePayload(paired_core_id: currentPairedCoreID)),
                contentType: "application/json"
            ))
        case ("com.roonlabs.pairing:1", "com.roonlabs.pairing:1/unsubscribe_pairing"):
            subscriptionHandlers.removeValue(forKey: requestID)
            try await transport.send(try MooCodec.encodeMessage(
                verb: .complete,
                name: "Unsubscribed",
                requestID: requestID,
                body: nil,
                contentType: nil
            ))
        case ("com.roonlabs.pairing:1", "com.roonlabs.pairing:1/pair"):
            currentPairedCoreID = currentCoreID
            try await transport.send(try MooCodec.encodeMessage(
                verb: .complete,
                name: "Success",
                requestID: requestID,
                body: nil,
                contentType: nil
            ))
        default:
            try await transport.send(try MooCodec.encodeMessage(
                verb: .complete,
                name: "InvalidRequest",
                requestID: requestID,
                body: try JSONEncoder().encode(["error": "unsupported request"]),
                contentType: "application/json"
            ))
        }
    }

    private func nextRequestIdentifier() -> String {
        defer { nextRequestID += 1 }
        return String(nextRequestID)
    }

    private func flushBufferedMessages(for requestID: String) async {
        guard let buffered = bufferedMessages.removeValue(forKey: requestID) else {
            return
        }

        for message in buffered {
            if let handler = subscriptionHandlers[requestID] {
                handler(message)
                if message.verb == .complete {
                    subscriptionHandlers.removeValue(forKey: requestID)
                }
                continue
            }

            if let continuation = pendingRequests.removeValue(forKey: requestID) {
                continuation.resume(returning: message)
            } else {
                bufferedMessages[requestID, default: []].append(message)
            }
        }
    }

    private func encodeRequestPayload<Body: Encodable>(
        name: String,
        body: Body?,
        requestID: String
    ) throws -> Data {
        let bodyData = try body.map { try JSONEncoder().encode($0) }
        return try MooCodec.encode(MooRequestEnvelope(
            requestID: requestID,
            endpoint: name,
            body: bodyData,
            contentType: bodyData == nil ? nil : "application/json"
        ))
    }
}
