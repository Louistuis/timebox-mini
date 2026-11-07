// tb: tiny command line client for the Divoom TimeBox-mini (11x11, classic Bluetooth).
// Protocol notes: github.com/MarcG046/timebox doc/protocol.md (a community draft).
//
//   tb selftest                 check the frame builder against the doc, no Bluetooth
//   tb sdp                      list the device's RFCOMM services and channel numbers
//   tb clock [12|24] [RRGGBB]   show the clock, optionally in a colour
//   tb temp [c|f] [RRGGBB]      show the temperature
//   tb light RRGGBB [0-100]     use the screen as a lamp;  tb off  turns it dark
//   tb brightness 0-100         display brightness
//   tb effect N / tb viz N      built-in effects 0-7 / music visualisers 0-6 (see PROTOCOL.md)
//   tb stopwatch / tb score R B stopwatch, scoreboard
//   tb game 0-5 [--auto steps]  play a built-in game from the keyboard (arrows, space, return, q)
//   tb scan [options]           send command bytes one by one and log the replies (see scan.swift)
//   tb time                     set the box's clock to this Mac's time
//   tb volume 0-15 / tb getview speaker volume / ask the box which view it shows
//   tb anim [delay]             8-frame test animation (delay in 100 ms steps)
//   tb view N [hex...]          switch to any view number with raw arguments
//   tb fill R G B               fill the whole screen (0-255 each)
//   tb test                     draw a colour gradient
//   tb raw <hex bytes>          send one raw frame: command byte then data, e.g. tb raw 45 00 01
//   tb serve [--port N] [--dry] pixel editor in the browser at http://127.0.0.1:8765
//
// Options before the command: --addr XX:XX:XX:XX:XX:XX  --channel 4
// Without --addr, tb uses $TB_ADDR, else the first paired device whose name starts with "TimeBox".

import Foundation
import IOBluetooth

let width = 11
let height = 11

// MARK: framing

/// 0x01, escaped(length LE, command, data, checksum LE), 0x02.
/// Length counts its own two bytes, checksum is the plain sum of everything before it.
func frame(cmd: UInt8, data: [UInt8]) -> [UInt8] {
    let len = UInt16(2 + 1 + data.count)
    var payload: [UInt8] = [UInt8(len & 0xff), UInt8(len >> 8), cmd] + data
    let sum = payload.reduce(UInt16(0)) { $0 &+ UInt16($1) }
    payload += [UInt8(sum & 0xff), UInt8(sum >> 8)]

    var out: [UInt8] = [0x01]
    for b in payload {
        if b >= 0x01 && b <= 0x03 { out += [0x03, b + 3] } else { out.append(b) }
    }
    out.append(0x02)
    return out
}

/// 4 bits per colour channel, R then G then B per pixel, row by row.
/// First nibble goes in the low half of a byte. 363 nibbles pack into 182 bytes.
func imageData(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    var nibbles: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            nibbles += [r >> 4, g >> 4, b >> 4]
        }
    }
    if nibbles.count % 2 == 1 { nibbles.append(0) }
    var bytes: [UInt8] = []
    var i = 0
    while i < nibbles.count {
        bytes.append(nibbles[i] | (nibbles[i + 1] << 4))
        i += 2
    }
    return bytes
}

/// Static image command. The header 00 0a 0a 04 is copied verbatim from the doc.
func imageFrame(_ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    frame(cmd: 0x44, data: [0x00, 0x0a, 0x0a, 0x04] + imageData(pixel))
}

/// One frame of an animation (0x49): same header and pixels as an image, plus the frame
/// index and a delay byte. Measured on camera, the box shows the frame for
/// (max(delay, 1) + 1) × 100 ms, so 200 ms at least, and always loops all 12 slots.
func animFrame(index: Int, delay: UInt8, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
    frame(cmd: 0x49, data: [0x00, 0x0a, 0x0a, 0x04, UInt8(index), delay] + imageData(pixel))
}

/// The box always loops all 12 frame slots, each shown for at least 200 ms. So a loop of
/// fewer frames is spread over all 12 slots: the sequence is repeated as often as fits, then
/// each frame's time (in 100 ms steps) is split over extra slots.
/// Returns, for each of the 12 slots, which input frame to show and for how many 100 ms steps
/// (2-256; the delay byte to send is that minus 1). Frames shorter than 200 ms are shown for
/// 200 ms. The loop keeps its exact timing whenever possible; loops too short to fill 12
/// slots are stretched a little.
func fillSlots(_ delays: [Int]) -> [(frame: Int, delay: Int)] {
    let slotCount = 12, minUnits = 2
    let n = min(delays.count, slotCount)
    guard n > 0 else { return [] }
    let ds = delays.prefix(n).map { max(minUnits, min($0, 256)) }
    let total = ds.reduce(0, +)
    let fewest = max(1, min((slotCount * minUnits + total - 1) / total, slotCount / n))

    // Repeat the sequence `reps` times and split entries until there are 12 slots.
    // Returns nil instead when that needs stretching and `exact` is set.
    func plan(_ reps: Int, exact: Bool) -> [(frame: Int, delay: Int)]? {
        var frame: [Int] = []
        var units: [Int] = []
        for _ in 0..<reps {
            frame += Array(0..<n)
            units += ds
        }
        var slots = Array(repeating: 1, count: frame.count)
        for _ in frame.count..<slotCount {
            // Give the next slot to the entry with the most time per slot that can still be split.
            if let j = units.indices.filter({ units[$0] >= minUnits * (slots[$0] + 1) })
                .max(by: { Double(units[$0]) / Double(slots[$0]) < Double(units[$1]) / Double(slots[$1]) }) {
                slots[j] += 1
            } else if exact {
                return nil
            } else {
                // Nothing left to split: stretch the longest entry just enough for one more slot.
                let j = units.indices.max(by: { units[$0] < units[$1] })!
                slots[j] += 1
                units[j] = max(units[j], minUnits * slots[j])
            }
        }
        var out: [(frame: Int, delay: Int)] = []
        for j in frame.indices {
            let base = units[j] / slots[j], extra = units[j] % slots[j]
            for s in 0..<slots[j] { out.append((frame[j], min(256, base + (s < extra ? 1 : 0)))) }
        }
        return out
    }

    // More repeats leave fewer slots to split, so try them in turn before stretching.
    for reps in fewest...max(fewest, slotCount / n) {
        if let exact = plan(reps, exact: true) { return exact }
    }
    return plan(fewest, exact: false)!
}

/// "ff8800" or "#ff8800" to [r, g, b].
func rgb(_ s: String) -> [UInt8]? {
    let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return [UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
}

/// Set date and time (0x18): year % 100, century, month, day, hour, minute, second, weekday (0 = Sunday).
func timeFrame(_ date: Date = Date()) -> [UInt8] {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    let parts = [c.year! % 100, c.year! / 100, c.month!, c.day!, c.hour!, c.minute!, c.second!, c.weekday! - 1]
    return frame(cmd: 0x18, data: parts.map { UInt8($0) })
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: bluetooth

final class Link: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var quiet = false
    /// Everything received, for callers that parse replies themselves.
    var received: [UInt8] = []
    var closed = false

    // Draining incoming data matters: the doc says unread replies can crash the box.
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeBufferPointer(start: dataPointer.assumingMemoryBound(to: UInt8.self),
                                              count: dataLength))
        received += bytes
        if !quiet { print("<- \(hex(bytes))") }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        closed = true
    }
}

/// Splits received bytes into frames (01 ... 02) and unescapes them. Returns the payload
/// after the length bytes (so it starts with 04, cmd, status) and whether the checksum held.
func parseReplies(_ bytes: [UInt8]) -> [(payload: [UInt8], ok: Bool)] {
    var out: [(payload: [UInt8], ok: Bool)] = []
    var i = 0
    while let start = bytes[i...].firstIndex(of: 0x01), let end = bytes[start...].firstIndex(of: 0x02) {
        var body: [UInt8] = []
        var j = start + 1
        while j < end {
            if bytes[j] == 0x03, j + 1 < end { body.append(bytes[j + 1] &- 3); j += 2 } else { body.append(bytes[j]); j += 1 }
        }
        if body.count >= 4 {
            let content = Array(body[0..<(body.count - 2)])
            let sum = content.reduce(UInt16(0)) { $0 &+ UInt16($1) }
            let ok = UInt16(body[body.count - 2]) | UInt16(body[body.count - 1]) << 8 == sum
            out.append((Array(content.dropFirst(2)), ok))
        }
        i = end + 1
        if i >= bytes.count { break }
    }
    return out
}

func parseAddress(_ s: String) -> IOBluetoothDevice? {
    IOBluetoothDevice(addressString: s.replacingOccurrences(of: ":", with: "-"))
}

func send(_ frames: [[UInt8]], addr: String, channel: UInt8, gap: TimeInterval = 0.6) {
    guard let device = parseAddress(addr) else { fail("bad address \(addr)") }
    let link = Link()
    var chan: IOBluetoothRFCOMMChannel? = nil
    // The box often refuses a reconnect right after the last channel closed, so retry a few times.
    var r = kIOReturnError
    for attempt in 1...4 {
        r = device.openRFCOMMChannelSync(&chan, withChannelID: channel, delegate: link)
        if r == kIOReturnSuccess { break }
        print("open attempt \(attempt) failed (IOReturn \(String(format: "0x%x", r))), retrying")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
    guard r == kIOReturnSuccess, let ch = chan else {
        fail("could not open RFCOMM channel \(channel) (IOReturn \(String(format: "0x%x", r))). Run `tb sdp` to see the real channel.")
    }
    print("connected, channel \(channel), mtu \(ch.getMTU())")
    RunLoop.current.run(until: Date().addingTimeInterval(0.8)) // greeting

    let mtu = max(Int(ch.getMTU()), 20)
    for f in frames {
        print("-> \(hex(f))")
        var offset = 0
        while offset < f.count {
            var chunk = Array(f[offset..<min(offset + mtu, f.count)])
            let w = ch.writeSync(&chunk, length: UInt16(chunk.count))
            if w != kIOReturnSuccess { fail("write failed (IOReturn \(String(format: "0x%x", w)))") }
            offset += chunk.count
        }
        RunLoop.current.run(until: Date().addingTimeInterval(gap))
    }
    ch.close()
}

func listServices(addr: String) {
    guard let device = parseAddress(addr) else { fail("bad address \(addr)") }
    print("name: \(device.name ?? "?"), connected: \(device.isConnected())")
    device.performSDPQuery(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(4))
    let records = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
    if records.isEmpty { print("no SDP records returned") }
    for rec in records {
        var id: BluetoothRFCOMMChannelID = 0
        let hasChannel = rec.getRFCOMMChannelID(&id) == kIOReturnSuccess
        print("\(rec.getServiceName() ?? "(unnamed)"): \(hasChannel ? "RFCOMM channel \(id)" : "no RFCOMM channel")")
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

// MARK: main

var args = Array(CommandLine.arguments.dropFirst())
var addrOption: String? = nil
var resolvedAddr: String? = nil
var channel: UInt8 = 4
while let first = args.first, first.hasPrefix("--") {
    guard args.count >= 2 else { fail("\(first) needs a value") }
    switch first {
    case "--addr": addrOption = args[1]
    case "--channel": guard let c = UInt8(args[1]) else { fail("bad channel") }; channel = c
    default: fail("unknown option \(first)")
    }
    args.removeFirst(2)
}
/// The box's address: --addr, then $TB_ADDR, then the first paired device named TimeBox-something.
func pairedTimeBox() -> String? {
    let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    let box = devices.first { ($0.name ?? "").lowercased().hasPrefix("timebox") }
    return box?.addressString?.replacingOccurrences(of: "-", with: ":")
}
var addr: String {
    if let a = resolvedAddr { return a }
    guard let a = addrOption ?? ProcessInfo.processInfo.environment["TB_ADDR"] ?? pairedTimeBox() else {
        fail("no TimeBox found: pair it in Bluetooth settings, or pass --addr XX:XX:XX:XX:XX:XX (or set TB_ADDR)")
    }
    resolvedAddr = a
    return a
}
guard let command = args.first else { fail("usage: tb [--addr A] [--channel N] selftest|sdp|clock|fill|test|raw") }
let rest = Array(args.dropFirst())

switch command {
case "selftest":
    // Example frame from the doc: set view clock 24h, with the 0x01 escaped.
    let got = frame(cmd: 0x45, data: [0x00, 0x01])
    let want: [UInt8] = [0x01, 0x05, 0x00, 0x45, 0x00, 0x03, 0x04, 0x4b, 0x00, 0x02]
    print(got == want ? "ok frame matches doc example" : "FAIL got \(hex(got)) want \(hex(want))")
    let img = imageData { _, _ in (255, 255, 255) }
    print(img.count == 182 ? "ok image data is 182 bytes" : "FAIL image data is \(img.count) bytes")
    let f = imageFrame { _, _ in (0, 0, 0) }
    print(f[1] == 0xbd && f[2] == 0x00 ? "ok image length field is bd 00" : "FAIL image length \(hex(Array(f.prefix(4))))")
    // Slot filling: always 12 slots, every delay at least 1, loop time kept when possible.
    var slotsOK = true
    for (delays, keepsTime) in [([5, 5, 5, 5], true), ([3, 3, 3, 3, 3], false), ([2], true), ([1, 1], false),
                                ([4, 4, 4, 4, 4], true), ([4, 2, 7, 2, 2, 3, 2, 9, 3, 3, 2, 2], true),
                                ([255, 255], true), ([256], true), ([3], true), ([2, 3, 2, 3, 2, 3, 2], false)] {
        let s = fillSlots(delays)
        let loop = s.reduce(0) { $0 + $1.delay }
        let total = delays.reduce(0, +)
        let fine = s.count == 12 && s.allSatisfy { $0.delay >= 2 && $0.delay <= 256 } && (!keepsTime || loop % total == 0)
        if !fine { print("FAIL fillSlots \(delays) -> \(s)"); slotsOK = false }
    }
    if slotsOK { print("ok animation slot filling") }
    exit(got == want && img.count == 182 && slotsOK ? 0 : 1)
case "sdp":
    listServices(addr: addr)
case "clock":
    // tb clock [12|24] [RRGGBB]
    let mode: UInt8 = rest.contains("12") ? 0 : 1
    let colour = rest.compactMap(rgb).first ?? []
    send([frame(cmd: 0x45, data: [0x00, mode] + colour)], addr: addr, channel: channel)
case "temp":
    // tb temp [c|f] [RRGGBB]
    let unit: UInt8 = rest.contains("f") ? 1 : 0
    let colour = rest.compactMap(rgb).first ?? []
    send([frame(cmd: 0x45, data: [0x01, unit] + colour + (colour.isEmpty ? [] : [0x00]))], addr: addr, channel: channel)
case "light":
    // tb light RRGGBB [brightness 0-100]: the whole screen as a lamp
    guard let first = rest.first, let colour = rgb(first) else { fail("usage: tb light RRGGBB [0-100]") }
    let level = rest.count > 1 ? UInt8(rest[1]) ?? 100 : 100
    send([frame(cmd: 0x45, data: [0x02] + colour + [level, 0x00])], addr: addr, channel: channel)
case "off":
    send([frame(cmd: 0x45, data: [0x02, 0x01, 0x01, 0x01, 0x00, 0x00])], addr: addr, channel: channel)
case "brightness":
    guard let v = rest.first.flatMap({ UInt8($0) }), v <= 100 else { fail("usage: tb brightness 0-100") }
    send([frame(cmd: 0x74, data: [v])], addr: addr, channel: channel)
case "effect":
    guard let n = rest.first.flatMap({ UInt8($0) }) else { fail("usage: tb effect N") }
    send([frame(cmd: 0x45, data: [0x03, n])], addr: addr, channel: channel)
case "viz":
    // tb viz N [fg RRGGBB] [bg RRGGBB]: music visualiser
    guard let n = rest.first.flatMap({ UInt8($0) }) else { fail("usage: tb viz N [fg] [bg]") }
    let fg = rest.count > 1 ? rgb(rest[1]) ?? [0, 0, 0] : [0, 0, 0]
    let bg = rest.count > 2 ? rgb(rest[2]) ?? [255, 255, 255] : [255, 255, 255]
    send([frame(cmd: 0x45, data: [0x04, n] + fg + bg)], addr: addr, channel: channel)
case "view":
    // tb view N [extra hex bytes]: switch to any view number directly
    let bytes = rest.compactMap { UInt8($0, radix: 16) }
    guard !bytes.isEmpty, bytes.count == rest.count else { fail("usage: tb view N [hex...]") }
    send([frame(cmd: 0x45, data: bytes)], addr: addr, channel: channel)
case "stopwatch":
    send([frame(cmd: 0x45, data: [0x06, 0x00])], addr: addr, channel: channel)
case "score":
    guard rest.count == 2, let red = UInt16(rest[0]), let blue = UInt16(rest[1]) else { fail("usage: tb score RED BLUE") }
    send([frame(cmd: 0x45, data: [0x07, UInt8(red & 0xff), UInt8(red >> 8), UInt8(blue & 0xff), UInt8(blue >> 8)])],
         addr: addr, channel: channel)
case "time":
    send([timeFrame()], addr: addr, channel: channel)
case "volume":
    guard let v = rest.first.flatMap({ UInt8($0) }), v <= 15 else { fail("usage: tb volume 0-15") }
    send([frame(cmd: 0x08, data: [v])], addr: addr, channel: channel)
case "getview":
    send([frame(cmd: 0x46, data: [])], addr: addr, channel: channel, gap: 1.0)
case "scan":
    scan(addr: addr, channel: channel, options: rest)
case "game":
    // tb game N [--auto "go,1.5,left,ok"]
    guard let n = rest.first.flatMap({ UInt8($0) }) else { fail("usage: tb game 0-5 [--auto steps]") }
    // Games 0-5 exist. Starting 6 or higher froze our box: no buttons, no Bluetooth.
    if n > 5 && !rest.contains("--force") { fail("game \(n) does not exist on the TimeBox-mini; trying 6-9 froze our box (add --force to try anyway)") }
    let auto = rest.firstIndex(of: "--auto").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
    playGame(n, addr: addr, channel: channel, auto: auto)
case "blink":
    // tb blink D: 12 slots alternating red and blue, each with raw delay byte D (for timing tests)
    let d = rest.first.flatMap { UInt8($0) } ?? 5
    let frames = (0..<12).map { i in animFrame(index: i, delay: d) { _, _ in i % 2 == 0 ? (255, 0, 0) : (0, 0, 255) } }
    send(frames, addr: addr, channel: channel, gap: 0.3)
case "anim":
    // tb anim [delay in 100 ms steps] [--frames N]
    // A 3x3 square going round the edge in N frames (default 8), spread over the box's 12 slots.
    let delay = rest.first.flatMap { Int($0) } ?? 2
    var count = 8
    if let i = rest.firstIndex(of: "--frames"), i + 1 < rest.count, let n = Int(rest[i + 1]) { count = max(1, min(n, 12)) }
    // The 32 positions round the edge for the square's top-left corner, clockwise.
    let ring = (0..<8).map { ($0, 0) } + (0..<8).map { (8, $0) } + (0..<8).map { (8 - $0, 8) } + (0..<8).map { (0, 8 - $0) }
    let pictures = (0..<count).map { i -> (Int, Int) -> (UInt8, UInt8, UInt8) in
        let spot = ring[i * ring.count / count]
        let h = Double(i) / Double(count) * 6
        let c = { (k: Double) -> UInt8 in UInt8(max(0, min(1, abs((h + k).truncatingRemainder(dividingBy: 6) - 3) - 1)) * 255) }
        return { x, y in (x >= spot.0 && x < spot.0 + 3 && y >= spot.1 && y < spot.1 + 3) ? (c(0), c(4), c(2)) : (0, 0, 0) }
    }
    let frames = fillSlots(Array(repeating: delay, count: count)).enumerated().map { slot, s in
        animFrame(index: slot, delay: UInt8(s.delay - 1), pictures[s.frame])
    }
    send(frames, addr: addr, channel: channel, gap: 0.3)
case "fill":
    guard rest.count == 3, let r = UInt8(rest[0]), let g = UInt8(rest[1]), let b = UInt8(rest[2]) else { fail("usage: tb fill R G B") }
    send([imageFrame { _, _ in (r, g, b) }], addr: addr, channel: channel)
case "test":
    send([imageFrame { x, y in (UInt8(x * 25), UInt8(y * 25), 128) }], addr: addr, channel: channel)
case "serve":
    // tb serve [--port 8765] [--dry]   dry never touches Bluetooth, for testing the editor
    var port: UInt16 = 8765
    if let i = rest.firstIndex(of: "--port"), i + 1 < rest.count, let p = UInt16(rest[i + 1]) { port = p }
    let dry = rest.contains("--dry")
    serve(port: port, session: Session(addr: dry ? (addrOption ?? "dry") : addr, channel: channel, dry: dry))
case "ramp":
    // Row 0 red ramp, row 1 green ramp, row 2 blue ramp, row 3 white ramp, rest black.
    // Each ramp goes from black at the left to full colour at the right.
    send([imageFrame { x, y in
        let v = UInt8(x * 25)
        switch y {
        case 0: return (v, 0, 0)
        case 1: return (0, v, 0)
        case 2: return (0, 0, v)
        case 3: return (v, v, v)
        default: return (0, 0, 0)
        }
    }], addr: addr, channel: channel)
case "walk":
    // Lights one pixel at a time in the order we send them: pixel 0 red, then white.
    // Watching where it travels shows how the box maps our bytes onto its screen.
    let gap = rest.first.flatMap { Double($0) } ?? 0.3
    let frames = (0..<(width * height)).map { n in
        imageFrame { x, y in
            y * width + x == n ? (n == 0 ? (255, 0, 0) : (255, 255, 255)) : (0, 0, 0)
        }
    }
    send(frames, addr: addr, channel: channel, gap: gap)
case "raw":
    let bytes = rest.compactMap { UInt8($0, radix: 16) }
    guard bytes.count == rest.count, let cmd = bytes.first else { fail("usage: tb raw <cmd> [data...] in hex") }
    send([frame(cmd: cmd, data: Array(bytes.dropFirst()))], addr: addr, channel: channel)
default:
    fail("unknown command \(command)")
}
