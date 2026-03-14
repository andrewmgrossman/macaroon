import Foundation

enum FixtureCaptureConfiguration {
    static var captureDirectoryURL: URL? {
        if let explicit = ProcessInfo.processInfo.environment["MACAROON_CAPTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           explicit.isEmpty == false {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }

        let enabled = ProcessInfo.processInfo.environment["MACAROON_CAPTURE_FIXTURES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard enabled == "1" || enabled == "true" || enabled == "yes" else {
            return nil
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-fixtures", isDirectory: true)
    }

    static var helperEnvironment: [String: String] {
        guard let captureDirectoryURL else {
            return [:]
        }

        return [
            "MACAROON_HELPER_CAPTURE_DIR": captureDirectoryURL.path
        ]
    }
}

final class FixtureCaptureRecorder {
    private let baseDirectoryURL: URL
    private let bridgeTranscriptURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init?(baseDirectoryURL: URL?, fileManager: FileManager = .default) {
        guard let baseDirectoryURL else {
            return nil
        }

        self.baseDirectoryURL = baseDirectoryURL
        self.bridgeTranscriptURL = baseDirectoryURL.appendingPathComponent("bridge-lines.jsonl")
        self.fileManager = fileManager
    }

    func prepareIfNeeded() throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: bridgeTranscriptURL.path) == false {
            fileManager.createFile(atPath: bridgeTranscriptURL.path, contents: nil)
        }
    }

    func recordOutbound(_ payload: Data) {
        append(kind: "outbound", payload: payload)
    }

    func recordInboundLine(_ payload: Data) {
        append(kind: "inbound", payload: payload)
    }

    private func append(kind: String, payload: Data) {
        guard let payloadString = String(data: payload, encoding: .utf8) else {
            return
        }

        let line = """
        {"timestamp":"\(ISO8601DateFormatter().string(from: Date()))","kind":"\(kind)","payload":\(JSONObjectEscaper.quote(payloadString))}
        """

        lock.lock()
        defer { lock.unlock() }

        guard let handle = try? FileHandle(forWritingTo: bridgeTranscriptURL) else {
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

private enum JSONObjectEscaper {
    static func quote(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        guard
            let data,
            var arrayString = String(data: data, encoding: .utf8),
            arrayString.first == "[",
            arrayString.last == "]"
        else {
            return "\"\""
        }

        arrayString.removeFirst()
        arrayString.removeLast()
        return arrayString
    }
}
