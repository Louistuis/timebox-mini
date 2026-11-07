// `tb game N`: starts one of the box's built-in games and keeps the connection open, since
// the box leaves the game as soon as the connection drops. Keys: arrows move, space = go,
// return = ok, q = quit. `--auto "go,1.5,left,ok"` plays a script instead (numbers are pauses
// in seconds), for filming.
//
// Commands (from hass-divoom, confirmed on the device): a0 01 N start game N, a0 00 00 stop,
// 88 = go, 17 K / 21 K = key K down / up with K: 1 left, 2 right, 3 up, 4 down, 5 ok.

import Foundation
import IOBluetooth

func playGame(_ number: UInt8, addr: String, channel: UInt8, auto: String?) {
    guard let device = parseAddress(addr) else { fail("bad address \(addr)") }
    let link = Link()
    link.quiet = true
    var chan: IOBluetoothRFCOMMChannel? = nil
    var opened = false
    for _ in 1...4 {
        if device.openRFCOMMChannelSync(&chan, withChannelID: channel, delegate: link) == kIOReturnSuccess { opened = true; break }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    }
    guard opened, let ch = chan else { fail("could not connect") }
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))

    func send(_ cmd: UInt8, _ data: [UInt8] = []) {
        var f = frame(cmd: cmd, data: data)
        _ = ch.writeSync(&f, length: UInt16(f.count))
    }
    func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    let keys: [String: UInt8] = ["left": 1, "right": 2, "up": 3, "down": 4, "ok": 5]
    func press(_ name: String) {
        if name == "go" { send(0x88); return }
        guard let k = keys[name] else { return }
        send(0x17, [k])
        pump(0.1)
        send(0x21, [k])
    }

    send(0xa0, [0x01, number])
    print("game \(number) started")

    if let auto = auto {
        for step in auto.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let pause = Double(step) { pump(pause) } else { print("key \(step)"); press(step); pump(0.3) }
        }
    } else {
        print("arrows move, space = go, return = ok, q = quit")
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }

        var pending: [UInt8] = []
        var quit = false
        FileHandle.standardInput.readabilityHandler = { h in
            let d = h.availableData
            DispatchQueue.main.async { pending += d }
        }
        while !quit {
            pump(0.02)
            while !pending.isEmpty {
                let b = pending.removeFirst()
                switch b {
                case UInt8(ascii: "q"): quit = true
                case UInt8(ascii: " "): press("go")
                case 10, 13: press("ok")
                case 27 where pending.count >= 2 && pending[0] == UInt8(ascii: "["):
                    let arrow = pending[1]
                    pending.removeFirst(2)
                    switch arrow {
                    case UInt8(ascii: "A"): press("up")
                    case UInt8(ascii: "B"): press("down")
                    case UInt8(ascii: "C"): press("right")
                    case UInt8(ascii: "D"): press("left")
                    default: break
                    }
                default: break
                }
            }
        }
        FileHandle.standardInput.readabilityHandler = nil
    }
    send(0xa0, [0x00, 0x00])
    pump(0.3)
    ch.close()
    print("game stopped")
}
