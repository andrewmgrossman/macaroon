import Foundation

#if MACAROON_DEBUG_LOGGING
enum DebugLoggingConfiguration {
    static let isCompiled = true

    static let sessionIdentifier: String = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }()

    static let sessionDirectoryURL: URL = {
        let baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-debug-logs", isDirectory: true)
        return baseDirectory.appendingPathComponent(sessionIdentifier, isDirectory: true)
    }()
}

private enum DebugLogCategory: String {
    case app = "app-events"
    case protocolTraffic = "protocol"
    case error = "errors"
}

private struct DebugLogEntry: Encodable {
    var timestamp: String
    var category: String
    var event: String
    var details: [String: String]
    var message: String?
}

actor DebugLogRecorder {
    static let shared = DebugLogRecorder(directoryURL: DebugLoggingConfiguration.sessionDirectoryURL)

    private let directoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let maxFileBytes = 2_000_000
    private let maxRotatedFiles = 3

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.withoutEscapingSlashes]
    }

    fileprivate func append(
        category: DebugLogCategory,
        event: String,
        details: [String: String],
        message: String?
    ) async {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fileURL = directoryURL.appendingPathComponent("\(category.rawValue).jsonl")
            try rotateIfNeeded(fileURL: fileURL)

            let entry = DebugLogEntry(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                category: category.rawValue,
                event: event,
                details: details,
                message: message
            )

            let data = try encoder.encode(entry)
            if fileManager.fileExists(atPath: fileURL.path) == false {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0a]))
        } catch {
            // Logging must never interfere with app behavior.
        }
    }

    private func rotateIfNeeded(fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maxFileBytes else {
            return
        }

        for index in stride(from: maxRotatedFiles, through: 1, by: -1) {
            let source = fileURL.appendingPathExtension("\(index)")
            let destination = fileURL.appendingPathExtension("\(index + 1)")
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }

        let rotated = fileURL.appendingPathExtension("1")
        if fileManager.fileExists(atPath: rotated.path) {
            try? fileManager.removeItem(at: rotated)
        }
        try fileManager.moveItem(at: fileURL, to: rotated)
    }
}

enum MacaroonDebugLogger {
    static var sessionDirectoryPath: String {
        DebugLoggingConfiguration.sessionDirectoryURL.path
    }

    static func logApp(_ event: String, details: [String: String] = [:], message: String? = nil) {
        Task {
            await DebugLogRecorder.shared.append(
                category: .app,
                event: event,
                details: details,
                message: sanitize(message)
            )
        }
    }

    static func logProtocol(_ event: String, details: [String: String] = [:], message: String? = nil) {
        Task {
            await DebugLogRecorder.shared.append(
                category: .protocolTraffic,
                event: event,
                details: details,
                message: sanitize(message)
            )
        }
    }

    static func logError(
        _ event: String,
        details: [String: String] = [:],
        error: (any Error)? = nil,
        message: String? = nil
    ) {
        let resolvedMessage = sanitize(message ?? error.map { String(describing: $0) })
        Task {
            await DebugLogRecorder.shared.append(
                category: .error,
                event: event,
                details: details,
                message: resolvedMessage
            )
        }
    }

    static func logProtocolMessage(direction: String, envelope: MooMessageEnvelope) {
        var details: [String: String] = [
            "direction": direction,
            "verb": envelope.verb.rawValue,
            "name": envelope.name
        ]
        if let requestID = envelope.requestID {
            details["request_id"] = requestID
        }
        if let service = envelope.service {
            details["service"] = service
        }
        if let contentType = envelope.contentType {
            details["content_type"] = contentType
        }
        let bodyText = envelope.body.flatMap(bodySummary)
        logProtocol("moo.message", details: details, message: bodyText)
    }

    static func logProtocolData(direction: String, label: String, data: Data) {
        if let envelope = try? MooCodec.decodeMessage(data) {
            logProtocolMessage(direction: direction, envelope: envelope)
            return
        }
        logProtocol(label, details: ["direction": direction, "bytes": String(data.count)], message: bodySummary(data))
    }

    static func bodySummary(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) {
            return sanitize(text)
        }
        return "<binary \(data.count) bytes>"
    }

    private static func sanitize(_ message: String?) -> String? {
        guard var sanitized = message, sanitized.isEmpty == false else {
            return message
        }

        let patterns = [
            #""token"\s*:\s*"[^"]+""#,
            #""authorization"\s*:\s*"[^"]+""#,
            #""Authorization"\s*:\s*"[^"]+""#
        ]

        for pattern in patterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "\"token\":\"<redacted>\"",
                options: .regularExpression
            )
        }
        return sanitized
    }
}
#else
enum DebugLoggingConfiguration {
    static let isCompiled = false
}

enum MacaroonDebugLogger {
    static var sessionDirectoryPath: String { "" }
    static func logApp(_: String, details _: [String: String] = [:], message _: String? = nil) {}
    static func logProtocol(_: String, details _: [String: String] = [:], message _: String? = nil) {}
    static func logError(_: String, details _: [String: String] = [:], error _: (any Error)? = nil, message _: String? = nil) {}
    static func logProtocolMessage(direction _: String, envelope _: MooMessageEnvelope) {}
    static func logProtocolData(direction _: String, label _: String, data _: Data) {}
    static func bodySummary(_: Data) -> String? { nil }
}
#endif
