import CryptoKit
import Foundation

enum NativeImageError: LocalizedError, Equatable, Sendable {
    case missingCoreEndpoint
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCoreEndpoint:
            return "No active Roon Core endpoint is available for image fetch."
        case .invalidResponse:
            return "The Roon Core returned an invalid image response."
        }
    }
}

struct NativeImageFetchResponse: Sendable {
    var contentType: String
    var data: Data
}

typealias NativeImageFetchClosure = @Sendable (URL) async throws -> NativeImageFetchResponse

actor NativeImageClient {
    private let fetch: NativeImageFetchClosure
    private let cacheDirectory: URL
    private let fileManager: FileManager

    init(
        fetch: NativeImageFetchClosure? = nil,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fetch = fetch ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw NativeImageError.invalidResponse
            }

            return NativeImageFetchResponse(
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg",
                data: data
            )
        }
        self.cacheDirectory = cacheDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("macaroon-artwork", isDirectory: true)
        self.fileManager = fileManager
    }

    func fetchImage(
        imageKey: String,
        width: Int,
        height: Int,
        format: String,
        core: CoreSummary
    ) async throws -> ImageFetchedResult {
        guard let host = core.host, let port = core.port else {
            throw NativeImageError.missingCoreEndpoint
        }

        let url = try imageURL(
            host: host,
            port: port,
            imageKey: imageKey,
            width: width,
            height: height,
            format: format
        )
        MacaroonDebugLogger.logProtocol(
            "image.fetch",
            details: [
                "image_key": imageKey,
                "width": String(width),
                "height": String(height),
                "format": format,
                "url": url.absoluteString
            ]
        )
        let response = try await fetch(url)
        MacaroonDebugLogger.logProtocol(
            "image.response",
            details: [
                "image_key": imageKey,
                "content_type": response.contentType,
                "bytes": String(response.data.count)
            ]
        )
        let fileURL = try writeCachedImage(
            imageKey: imageKey,
            data: response.data,
            contentType: response.contentType
        )

        return ImageFetchedResult(imageKey: imageKey, localURL: fileURL.path)
    }

    private func imageURL(
        host: String,
        port: Int,
        imageKey: String,
        width: Int,
        height: Int,
        format: String
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/api/image/\(imageKey)"
        components.queryItems = [
            URLQueryItem(name: "scale", value: "fit"),
            URLQueryItem(name: "width", value: String(width)),
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "format", value: format)
        ]

        guard let url = components.url else {
            throw NativeImageError.invalidResponse
        }
        return url
    }

    private func writeCachedImage(imageKey: String, data: Data, contentType: String) throws -> URL {
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let hashedName = Insecure.SHA1
            .hash(data: Data(imageKey.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = contentType == "image/png" ? "png" : "jpg"
        let fileURL = cacheDirectory.appendingPathComponent("\(hashedName).\(ext)")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
