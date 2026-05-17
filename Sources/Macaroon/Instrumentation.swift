import Foundation
import os

enum MacaroonLog {
    private static let subsystem = "com.andrewmg.macaroon"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let browse = Logger(subsystem: subsystem, category: "browse")
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let artwork = Logger(subsystem: subsystem, category: "artwork")
}
