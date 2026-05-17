import Foundation

enum NativeSessionTransportError: LocalizedError, Equatable, Sendable {
    case unavailable
    case requestTimedOut(String)
    case requestCancelled(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The native session transport is unavailable."
        case let .requestTimedOut(requestID):
            return "The native session request timed out: \(requestID)."
        case let .requestCancelled(requestID):
            return "The native session request was cancelled: \(requestID)."
        }
    }
}

actor NativeMooSession {
    private struct PendingRequest {
        var continuation: CheckedContinuation<MooMessageEnvelope, Error>
        var timeoutTask: Task<Void, Never>
    }

    private let transportFactory: @Sendable () -> any NativeMooTransportProtocol
    private let requestTimeoutSeconds: TimeInterval
    private let maxBufferedRequestIDs: Int
    private let maxBufferedMessagesPerRequest: Int
    private let receiveFailureHandler: (@Sendable (Error) -> Void)?
    private var transport: (any NativeMooTransportProtocol)?
    private var nextRequestID = 0
    private var pendingRequests: [String: PendingRequest] = [:]
    private var subscriptionHandlers: [String: @Sendable (MooMessageEnvelope) -> Void] = [:]
    private var bufferedMessages: [String: [MooMessageEnvelope]] = [:]
    private var receiveLoopTask: Task<Void, Never>?
    private var currentPairedCoreID: String?
    private var currentCoreID: String?

    init(
        transportFactory: @escaping @Sendable () -> any NativeMooTransportProtocol,
        currentPairedCoreID: String?,
        requestTimeoutSeconds: TimeInterval = 8,
        maxBufferedRequestIDs: Int = 64,
        maxBufferedMessagesPerRequest: Int = 16,
        receiveFailureHandler: (@Sendable (Error) -> Void)? = nil
    ) {
        self.transportFactory = transportFactory
        self.currentPairedCoreID = currentPairedCoreID
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxBufferedRequestIDs = max(1, maxBufferedRequestIDs)
        self.maxBufferedMessagesPerRequest = max(1, maxBufferedMessagesPerRequest)
        self.receiveFailureHandler = receiveFailureHandler
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
        continuations.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: NativeSessionTransportError.unavailable)
        }
        subscriptionHandlers.removeAll()
        bufferedMessages.removeAll()

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
            throw NativeSessionTransportError.unavailable
        }

        let requestID = nextRequestIdentifier()
        let payload = try encodeRequestPayload(name: name, body: body, requestID: requestID)
        MacaroonDebugLogger.logProtocolData(direction: "outbound", label: "moo.request", data: payload)
        MacaroonLog.transport.debug("MOO request id=\(requestID, privacy: .public) name=\(name, privacy: .public)")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerPendingRequest(requestID, continuation: continuation)
                Task {
                    do {
                        try await transport.send(payload)
                        await self.flushBufferedMessages(for: requestID)
                    } catch {
                        self.failPendingRequest(requestID, error: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.failPendingRequest(
                    requestID,
                    error: NativeSessionTransportError.requestCancelled(requestID)
                )
            }
        }
    }

    func subscribe<Body: Encodable>(
        _ name: String,
        body: Body?,
        handler: @escaping @Sendable (MooMessageEnvelope) -> Void
    ) async throws {
        try await observeRequest(name, body: body, handler: handler)
    }

    func observeRequest<Body: Encodable>(
        _ name: String,
        body: Body?,
        handler: @escaping @Sendable (MooMessageEnvelope) -> Void
    ) async throws {
        guard let transport else {
            throw NativeSessionTransportError.unavailable
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
                continuations.forEach {
                    $0.timeoutTask.cancel()
                    $0.continuation.resume(throwing: error)
                }
                receiveFailureHandler?(error)
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

            guard let pending = pendingRequests.removeValue(forKey: requestID) else {
                buffer(message, for: requestID)
                return
            }
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: message)
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

            if let pending = pendingRequests.removeValue(forKey: requestID) {
                pending.timeoutTask.cancel()
                pending.continuation.resume(returning: message)
            } else {
                buffer(message, for: requestID)
            }
        }
    }

    private func registerPendingRequest(
        _ requestID: String,
        continuation: CheckedContinuation<MooMessageEnvelope, Error>
    ) {
        let timeoutTask = Task { [requestTimeoutSeconds] in
            guard requestTimeoutSeconds > 0 else {
                return
            }
            let nanoseconds = UInt64((requestTimeoutSeconds * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanoseconds)
            self.failPendingRequest(
                requestID,
                error: NativeSessionTransportError.requestTimedOut(requestID)
            )
        }

        pendingRequests[requestID] = PendingRequest(
            continuation: continuation,
            timeoutTask: timeoutTask
        )
    }

    private func failPendingRequest(_ requestID: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func buffer(_ message: MooMessageEnvelope, for requestID: String) {
        if bufferedMessages[requestID] == nil,
           bufferedMessages.count >= maxBufferedRequestIDs,
           let firstKey = bufferedMessages.keys.sorted().first {
            bufferedMessages.removeValue(forKey: firstKey)
        }

        var messages = bufferedMessages[requestID, default: []]
        messages.append(message)
        if messages.count > maxBufferedMessagesPerRequest {
            messages.removeFirst(messages.count - maxBufferedMessagesPerRequest)
        }
        bufferedMessages[requestID] = messages
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
