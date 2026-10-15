// dead-center-bridge: the native-messaging host Chrome-family browsers, Firefox and Zen launch for the
// Dead Center extension. Each message is a native-endian UInt32 length followed by that many bytes of
// UTF-8 JSON, in both directions. Messages land in the shared inbox and wake the app; every message
// gets a framed {"ok":true} or {"ok":false,"error":"…"} back. stdout carries nothing but replies.
//
// Set DEAD_CENTER_BRIDGE_NO_WAKE=1 to deliver without opening the app (for testing).

import Foundation
import DCModel
import os

enum Bridge {
    private static let log = Logger(subsystem: "com.mason363.DeadCenter", category: "bridge")
    private static let maxMessageSize = 64 * 1024 * 1024
    private static let input = FileHandle.standardInput
    private static let output = FileHandle.standardOutput
    private static let shouldWake = ProcessInfo.processInfo.environment["DEAD_CENTER_BRIDGE_NO_WAKE"] == nil

    private enum Failure: Error {
        case truncated
    }

    /// Chrome-family browsers pass the caller's origin (chrome-extension://…/), Firefox and Zen the
    /// manifest path and the add-on ID. Used only when a message doesn't name its browser.
    private static let launchingBrowser: String? = {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains(where: { $0.hasPrefix("chrome-extension://") }) { return "chrome" }
        if arguments.contains(where: { $0.contains("@") || $0.hasSuffix(".json") }) { return "firefox" }
        return nil
    }()

    static func run() -> Never {
        // A browser that goes away mid-reply shouldn't kill us with SIGPIPE; the write fails instead.
        signal(SIGPIPE, SIG_IGN)
        do {
            while let header = try read(MemoryLayout<UInt32>.size) {
                let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
                if length > maxMessageSize {
                    // Skip the body so the stream stays in sync.
                    var remaining = length
                    while remaining > 0, let chunk = try read(min(remaining, 1 << 20)) { remaining -= chunk.count }
                    try reply(["ok": false, "error": "The page is too large (\(length / 1_048_576) MB)."])
                    continue
                }
                guard let body = try read(length) else { throw Failure.truncated }
                try reply(handle(body))
            }
            exit(0)
        } catch {
            log.error("Bridge stopped: \(String(describing: error), privacy: .public)")
            exit(1)
        }
    }

    private static func handle(_ body: Data) -> [String: Any] {
        do {
            let object = try JSONSerialization.jsonObject(with: body)
            let payload = try IncomingMessage.payload(from: object, defaultBrowser: launchingBrowser)
            let file = try IncomingMessage.deliver(payload)
            log.info("Delivered \(payload.kind.rawValue, privacy: .public) from \(payload.browser ?? "unknown", privacy: .public)")
            if let file, shouldWake {
                let app = Bundle.main.executableURL.flatMap { IncomingMessage.enclosingApp(of: $0, levels: 3) }
                IncomingMessage.wakeApp(for: file, preferring: app)
            }
            return ["ok": true]
        } catch {
            log.error("Rejected a message: \(String(describing: error), privacy: .public)")
            return ["ok": false, "error": String(describing: error)]
        }
    }

    /// Reads exactly `count` bytes; nil at a clean end of input.
    private static func read(_ count: Int) throws -> Data? {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try input.read(upToCount: min(count - data.count, 1 << 20)), !chunk.isEmpty else {
                if data.isEmpty { return nil }
                throw Failure.truncated
            }
            data.append(chunk)
        }
        return data
    }

    private static func reply(_ object: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: object)
        var length = UInt32(body.count)
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        try output.write(contentsOf: frame)
    }
}

Bridge.run()
