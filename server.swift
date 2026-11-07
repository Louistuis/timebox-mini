// `tb serve`: a tiny localhost web server that keeps one Bluetooth link open and
// lets editor.html draw on the TimeBox-mini.
//
//   GET  /          editor.html (read from disk on every request)
//   GET  /status    {"connected":bool,"dry":bool}
//   POST /connect   open the Bluetooth link now
//   POST /frame     body: 726 hex chars, RRGGBB for each of the 121 pixels, row by row
//   POST /clock     body: 12 or 24, optionally followed by RRGGBB
//   POST /view      body: hex bytes for view command 0x45, e.g. "03 05" = effect 5
//   POST /brightness body: 0-100
//   POST /lamp      body: RRGGBB level
//   POST /anim      body: up to 12 lines of "DELAY HEX726" (delay in 100 ms steps)

import Foundation
import IOBluetooth
import Network

// MARK: device session

/// One long-lived RFCOMM link. With dry set it never touches Bluetooth and only logs.
final class Session {
    let addr: String
    let channel: UInt8
    let dry: Bool
    private let link = Link()
    private var chan: IOBluetoothRFCOMMChannel?

    init(addr: String, channel: UInt8, dry: Bool) {
        self.addr = addr
        self.channel = channel
        self.dry = dry
        link.quiet = true
    }

    var isOpen: Bool { dry || (chan?.isOpen() ?? false) }

    func open() -> Bool {
        if isOpen { return true }
        guard let device = parseAddress(addr) else { return false }
        for attempt in 1...3 {
            var ch: IOBluetoothRFCOMMChannel? = nil
            let r = device.openRFCOMMChannelSync(&ch, withChannelID: channel, delegate: link)
            if r == kIOReturnSuccess, let c = ch {
                chan = c
                print("connected to \(addr) on channel \(channel), mtu \(c.getMTU())")
                return true
            }
            print("open attempt \(attempt) failed (IOReturn \(String(format: "0x%x", r)))")
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        return false
    }

    func write(_ bytes: [UInt8]) -> Bool {
        if dry { print("dry: \(bytes.count) bytes"); return true }
        guard open(), let ch = chan else { return false }
        let mtu = max(Int(ch.getMTU()), 20)
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset..<min(offset + mtu, bytes.count)])
            if ch.writeSync(&chunk, length: UInt16(chunk.count)) != kIOReturnSuccess {
                ch.close()
                chan = nil
                return false
            }
            offset += chunk.count
        }
        return true
    }

    func close() {
        chan?.close()
        chan = nil
    }
}

// MARK: http

struct Request {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = Data()
}

/// Returns nil until the whole request (head and body) has arrived.
func parseRequest(_ buf: Data) -> Request? {
    guard let split = buf.range(of: Data([13, 10, 13, 10])) else { return nil }
    let head = String(decoding: buf[0..<split.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let first = lines.removeFirst().split(separator: " ")
    guard first.count >= 2 else { return nil }
    var req = Request()
    req.method = String(first[0])
    req.path = String(first[1])
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon]).lowercased()
        req.headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let need = min(Int(req.headers["content-length"] ?? "0") ?? 0, 65536)
    guard buf.count - split.upperBound >= need else { return nil }
    req.body = buf[split.upperBound..<(split.upperBound + need)]
    return req
}

func reply(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data) {
    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(body)
    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
}

func text(_ s: String) -> Data { Data(s.utf8) }

/// 726 hex characters to 363 bytes, or nil if the text is malformed.
func parsePixels(_ body: Data) -> [UInt8]? {
    let chars = Array(String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    guard chars.count == width * height * 6 else { return nil }
    var bytes: [UInt8] = []
    var i = 0
    while i + 1 < chars.count {
        guard let v = UInt8(String(chars[i...(i + 1)]), radix: 16) else { return nil }
        bytes.append(v)
        i += 2
    }
    return bytes
}

func route(_ req: Request, conn: NWConnection, session: Session, port: UInt16, page: URL) {
    // Only this page, served from localhost, may talk to the device. This blocks other
    // websites from drawing on it through DNS rebinding or cross-site posts.
    let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
    let allowedOrigins = allowedHosts.map { "http://\($0)" }
    guard allowedHosts.contains(req.headers["host"] ?? "") else {
        return reply(conn, "403 Forbidden", "text/plain", text("bad host"))
    }
    if req.method == "POST", let origin = req.headers["origin"], !allowedOrigins.contains(origin) {
        return reply(conn, "403 Forbidden", "text/plain", text("bad origin"))
    }

    switch (req.method, req.path) {
    case ("GET", "/"), ("GET", "/index.html"):
        guard let html = try? Data(contentsOf: page) else {
            return reply(conn, "500 Internal Server Error", "text/plain", text("cannot read \(page.path)"))
        }
        reply(conn, "200 OK", "text/html; charset=utf-8", html)
    case ("GET", "/status"):
        reply(conn, "200 OK", "application/json",
              text("{\"connected\":\(session.isOpen),\"dry\":\(session.dry)}"))
    case ("POST", "/connect"):
        let ok = session.open()
        reply(conn, ok ? "200 OK" : "502 Bad Gateway", "text/plain", text(ok ? "ok" : "device unavailable"))
    case ("POST", "/frame"):
        guard let px = parsePixels(req.body) else {
            return reply(conn, "400 Bad Request", "text/plain", text("expected \(width * height * 6) hex characters"))
        }
        let f = imageFrame { x, y in
            let i = (y * width + x) * 3
            return (px[i], px[i + 1], px[i + 2])
        }
        let ok = session.write(f)
        reply(conn, ok ? "200 OK" : "502 Bad Gateway", "text/plain", text(ok ? "ok" : "device unavailable"))
    case ("POST", "/clock"):
        // body: "12" or "24", optionally followed by RRGGBB
        let words = String(decoding: req.body, as: UTF8.self).split(separator: " ").map(String.init)
        let mode: UInt8 = words.first == "12" ? 0 : 1
        let colour = words.dropFirst().compactMap(rgb).first ?? []
        let ok = session.write(frame(cmd: 0x45, data: [0x00, mode] + colour))
        reply(conn, ok ? "200 OK" : "502 Bad Gateway", "text/plain", text(ok ? "ok" : "device unavailable"))
    case ("POST", "/view"):
        // body: hex bytes for the 0x45 view command, e.g. "03 05" for effect 5
        let words = String(decoding: req.body, as: UTF8.self).split(separator: " ").map(String.init)
        let bytes = words.compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty, bytes.count == words.count, bytes.count <= 12, bytes[0] <= 7 else {
            return reply(conn, "400 Bad Request", "text/plain", text("expected view number 0-7 and hex arguments"))
        }
        let ok = session.write(frame(cmd: 0x45, data: bytes))
        reply(conn, ok ? "200 OK" : "502 Bad Gateway", "text/plain", text(ok ? "ok" : "device unavailable"))
    case ("POST", "/brightness"):
        guard let v = UInt8(String(decoding: req.body, as: UTF8.self).trimmingCharacters(in: .whitespaces)), v <= 100 else {
            return reply(conn, "400 Bad Request", "text/plain", text("expected 0-100"))
        }
        let ok = session.write(frame(cmd: 0x74, data: [v]))
        reply(conn, ok ? "200 OK" : "502 Bad Gateway", "text/plain", text(ok ? "ok" : "device unavailable"))
    case ("POST", "/lamp"):
        // body: "RRGGBB level"
        let words = String(decoding: req.body, as: UTF8.self).split(separator: " ").map(String.init)
        guard words.count == 2, let colour = rgb(words[0]), let level = UInt8(words[1]), level <= 100 else {
            return reply(conn, "400 Bad Request", "text/plain", text("expected RRGGBB 0-100"))
        }
        let ok = session.write(frame(cmd: 0x45, data: [0x02] + colour + [level, 0x00]))
        reply(conn, ok ? "200 OK" : "502 Bad Gateway", "text/plain", text(ok ? "ok" : "device unavailable"))
    case ("POST", "/anim"):
        // body: one line per frame, "DELAY HEX726", delay in 100 ms steps (1-255), at most 12 lines.
        // The frames are spread over all 12 slots by fillSlots, since the box always plays 12.
        let lines = String(decoding: req.body, as: UTF8.self).split(separator: "\n").map(String.init)
        var pictures: [[UInt8]] = []
        var delays: [Int] = []
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: " ").map(String.init)
            guard i < 12, parts.count == 2, let delay = UInt8(parts[0]), delay > 0,
                  let px = parsePixels(Data(parts[1].utf8)) else {
                return reply(conn, "400 Bad Request", "text/plain", text("bad frame \(i + 1)"))
            }
            pictures.append(px)
            delays.append(Int(delay))
        }
        guard !pictures.isEmpty else { return reply(conn, "400 Bad Request", "text/plain", text("no frames")) }
        let frames = fillSlots(delays).enumerated().map { slot, s in
            animFrame(index: slot, delay: UInt8(s.delay - 1)) { x, y in
                let p = (y * width + x) * 3
                return (pictures[s.frame][p], pictures[s.frame][p + 1], pictures[s.frame][p + 2])
            }
        }
        var ok = true
        for f in frames where ok {
            ok = session.write(f)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        reply(conn, ok ? "200 OK" : "502 Bad Gateway", "text/plain", text(ok ? "ok" : "device unavailable"))
    default:
        reply(conn, "404 Not Found", "text/plain", text("not found"))
    }
}

func handle(_ conn: NWConnection, session: Session, port: UInt16, page: URL) {
    conn.start(queue: .main)
    var buf = Data()
    func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, err in
            if let data = data { buf.append(data) }
            if let req = parseRequest(buf) {
                route(req, conn: conn, session: session, port: port, page: page)
            } else if done || err != nil || buf.count > 70000 {
                conn.cancel()
            } else {
                receive()
            }
        }
    }
    receive()
}

var interruptSource: DispatchSourceSignal?

func serve(port: UInt16, session: Session) -> Never {
    let page = Bundle.main.bundleURL.appendingPathComponent("editor.html")
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { fail("bad port") }

    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
    guard let listener = try? NWListener(using: params) else { fail("cannot listen on port \(port)") }
    listener.newConnectionHandler = { conn in
        handle(conn, session: session, port: port, page: page)
    }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: print("editor ready: http://127.0.0.1:\(port)  (Ctrl-C to stop)")
        case .failed(let e): fail("listener failed: \(e)")
        default: break
        }
    }
    listener.start(queue: .main)

    signal(SIGINT, SIG_IGN)
    interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interruptSource?.setEventHandler {
        session.close()
        print("bye")
        exit(0)
    }
    interruptSource?.resume()

    if !session.dry && !session.open() {
        print("device not reachable yet, the editor will retry on the first drawing")
    }
    dispatchMain()
}
