// `tb scan`: sends command bytes one by one over a single connection and records what the
// box answers, plus its state (0x46) after each, as JSON lines on stdout. Used to find
// commands that no documentation mentions. Times are Unix seconds, so a camera recording
// started from a shell can be lined up with them.
//
//   tb scan [--from 0] [--to ff] [--only "10 13"] [--args "hex ..."] [--skip "44 49"] [--wait 0.35]

import Foundation
import IOBluetooth

func scan(addr: String, channel: UInt8, options: [String]) {
    func option(_ name: String) -> String? {
        guard let i = options.firstIndex(of: name), i + 1 < options.count else { return nil }
        return options[i + 1]
    }
    let from = option("--from").flatMap { Int($0, radix: 16) ?? Int($0) } ?? 0
    let to = option("--to").flatMap { Int($0, radix: 16) ?? Int($0) } ?? 255
    let args = (option("--args") ?? "").split(separator: " ").compactMap { UInt8($0, radix: 16) }
    let skip = Set((option("--skip") ?? "").split(separator: " ").compactMap { UInt8($0, radix: 16) })
    let only = Set((option("--only") ?? "").split(separator: " ").compactMap { UInt8($0, radix: 16) })
    let wait = option("--wait").flatMap(Double.init) ?? 0.35

    guard let device = parseAddress(addr) else { fail("bad address \(addr)") }
    let link = Link()
    link.quiet = true
    var chan: IOBluetoothRFCOMMChannel?

    func open() -> Bool {
        for _ in 1...5 {
            var ch: IOBluetoothRFCOMMChannel? = nil
            link.closed = false
            if device.openRFCOMMChannelSync(&ch, withChannelID: channel, delegate: link) == kIOReturnSuccess, let c = ch {
                chan = c
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                link.received.removeAll()
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        return false
    }
    func write(_ bytes: [UInt8]) -> Bool {
        guard let ch = chan, !link.closed else { return false }
        var b = bytes
        return ch.writeSync(&b, length: UInt16(b.count)) == kIOReturnSuccess
    }
    func collect(_ seconds: Double) -> [UInt8] {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        defer { link.received.removeAll() }
        return link.received
    }
    func json(_ fields: [(String, String)]) -> String {
        "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }
    func q(_ s: String) -> String { "\"\(s)\"" }
    func replies(_ raw: [UInt8]) -> String {
        "[" + parseReplies(raw).map { q(hex($0.payload) + ($0.ok ? "" : " BADSUM")) }.joined(separator: ",") + "]"
    }

    guard open() else { fail("could not connect") }
    setvbuf(stdout, nil, _IOLBF, 0)

    for cmd in from...to {
        let c = UInt8(cmd)
        if skip.contains(c) || (!only.isEmpty && !only.contains(c)) { continue }
        let t = Date().timeIntervalSince1970
        var sent = write(frame(cmd: c, data: args))
        if !sent {
            print(json([("event", q("reconnect")), ("cmd", "\(cmd)"), ("t", String(format: "%.3f", t))]))
            sent = open() && write(frame(cmd: c, data: args))
            if !sent {
                print(json([("event", q("lost")), ("cmd", "\(cmd)")]))
                return
            }
        }
        let reply = collect(wait)
        let stateSent = write(frame(cmd: 0x46, data: []))
        let state = stateSent ? collect(0.3) : []
        print(json([("cmd", "\(cmd)"), ("hex", q(String(format: "%02x", cmd))), ("t", String(format: "%.3f", t)),
                    ("reply", replies(reply)), ("state", replies(state)), ("closed", link.closed ? "true" : "false")]))
        if link.closed { chan = nil }
    }
    chan?.close()
}
