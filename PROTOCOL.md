# Divoom TimeBox-mini protocol

What we know about talking to the TimeBox-mini (11×11 LEDs, classic Bluetooth), checked
against a real device on 2026-11-07. Sources: the community draft
[MarcG046/timebox doc/protocol.md](https://github.com/MarcG046/timebox/blob/master/doc/protocol.md),
the TimeBox-mini driver in [d03n3rfr1tz3/hass-divoom](https://github.com/d03n3rfr1tz3/hass-divoom),
[ScR4tCh/timebox](https://github.com/ScR4tCh/timebox) and
[mathoudebine/homeassistant-timebox-mini](https://github.com/mathoudebine/homeassistant-timebox-mini).
Everything marked **verified** was confirmed on the device itself.

## Connection

- Bluetooth name `TimeBox-mini-audio`. The display is driven over RFCOMM **channel 4**
  (SDP name "Serial Port 1"). Channel 1 is hands-free audio. **Verified.**
- On connect the box sends `00 05 48 45 4c 4c 4f 00` ("HELLO"), unframed. **Verified.**
- Reconnecting right after closing often fails once (IOReturn `0xe00002bc`); retrying after
  about 1.5 s works. **Verified.**
- Keep reading what the box sends. The draft doc warns that unread replies can crash it.

## Framing

```
01  escaped( len_lo len_hi  cmd  data...  sum_lo sum_hi )  02
```

- `len` counts itself, the command byte and the data (so `len = 3 + data length`).
- `sum` is the 16-bit sum of every byte from `len_lo` through the last data byte.
- Inside the frame, `01`, `02` and `03` are escaped as `03 04`, `03 05` and `03 06`.
  This applies to the checksum too. **Verified** (the doc's example frame matches byte for byte).

## Replies

`01 escaped( len 04 cmd 55 [data] sum ) 02`. `55` means accepted, `AA` means rejected.
Most view commands echo the new view number after `55`. **Verified.**

- Brightness (`74`) is answered as command `32` with the level, for example `04 32 55 64`.
- Animation frames (`49`) get no reply at all.

## Commands

| Cmd | Data | What it does | Status |
|---|---|---|---|
| `44` | `00 0a 0a 04` + 182 pixel bytes | Show a still image (switches to view 5) | **Verified** |
| `49` | `00 0a 0a 04` `index` `delay` + 182 pixel bytes | One animation frame, see below | **Verified** |
| `45` | `view` `args...` | Switch view, see below | **Verified** |
| `46` | none | Read the current state, see below | **Verified** |
| `74` | level 0-100 | Display brightness | **Verified** |
| `18` | `yy` `cc` `month` `day` `hour` `min` `sec` `weekday` | Set the clock (year = cc·100 + yy, weekday 0 = Sunday) | **Verified** (accepted) |
| `08` | 0-15 | Speaker volume | From source, not tested |
| `05` | `00`/`01` | Radio off/on | From source, not tested |
| `43` | `hh mm 01 ff/00` | Alarm | From source, not tested (would ring) |
| `40` | `minutes mode on/off` | Sleep timer | From source, not tested |
| `42` | none | Read the 3 alarms, see below | **Verified** (read only) |
| `53` | none | Read the 10 reminders, one reply each, see below | **Verified** (read only) |
| `a0` | `01 N` / `00 00` | Start game N / leave the game, see Games | **Verified** |
| `88` | none | Game "go" button | **Verified** |
| `17` / `21` | `K` | Game key down / up: 1 left, 2 right, 3 up, 4 down, 5 ok | **Verified** |

The header `00 0a 0a 04` most likely means: flags 0, maximum x 10, maximum y 10, 4 bits per
colour channel (an interpretation, not tested).

### Pixel data

121 pixels, row by row from the top-left, 4 bits each of R, G, B in that order: 363 nibbles,
packed low nibble first into 182 bytes (the last high nibble is padding). Each channel is
the top 4 bits of an 8-bit value, so 16 levels per channel. **Verified** with solid fills,
per-channel ramps and a single-pixel walk across the whole screen.

### Animations

- The box has **12 frame slots** and always loops through all 12. Slots you don't
  overwrite keep their old frames, which then play after yours. **Verified.**
- `index` is the slot (0-11). A frame shows for **(max(delay, 1) + 1) × 100 ms**, so 200 ms
  at least: delay 0 and delay 1 both give 200 ms. Measured on camera with 12 alternating
  slots: delay 1, 3, 5 and 10 gave 200, 400, 600 and 1100 ms. **Verified.**
- Blank padding frames are therefore not skipped (they showed as a black gap of about
  1.6 s). A shorter loop has to be spread over the 12 slots instead: repeat the sequence
  as often as fits and split each frame's time over several slots. `fillSlots` in
  `main.swift` does this and keeps the loop's exact timing whenever possible. **Verified**:
  4 frames of 500 ms looped in 2000 ms (±33 ms, one camera frame).
- The first frame appears about 75 ms after the last frame is sent. Frames get no reply.

### Views (`45`)

| View | Args | Shows |
|---|---|---|
| `00` | `mode` [`r g b`] | Clock; mode `00` = 12 h, `01` = 24 h; optional digit colour |
| `01` | `unit` [`r g b 00`] | Temperature; unit `00` = °C, `01` = °F; optional colour |
| `02` | `r g b level mode` | Lamp: whole screen one colour at `level` 0-100. Level 0 = screen off |
| `03` | `n` | Built-in effect `n` (0-7, see below) |
| `04` | `n` [`fg rgb` `bg rgb`] | Music visualiser `n` (0-6, see below; the colours are not stored) |
| `05` | none | The last still image sent with `44` |
| `06` | `00` | Stopwatch (not remembered as the current view) |
| `07` | `red_lo red_hi blue_lo blue_hi` | Scoreboard (not remembered as the current view) |

An extra byte after the clock colour is accepted and ignored.

### Effects and visualisers

Filmed through the Mac's camera while stepping through numbers 0-15 (**verified**):

| Effect | Looks like |
|---|---|
| 0 | Two-colour diagonal wipes, colours keep changing |
| 1 | Pulsing diamond, swapping colours |
| 2 | Rectangles growing out from the edges |
| 3 | Twinkling coloured dots on blue |
| 4 | Green chevrons scrolling sideways |
| 5 | Countdown digits |
| 6 | Spinning coloured pinwheel |
| 7 | Purple fill with a line sweeping down |
| 8+ | Same as effect 0 |

| Visualiser | Looks like |
|---|---|
| 0 | Spectrum bars, white with red peak dots |
| 1 | Running figure |
| 2 | Two rainbow level meters at the sides |
| 3 | Horizontal rainbow waveform |
| 4 | Blue bars along the bottom |
| 5 | Flame |
| 6 | Face whose mouth moves |
| 7+ | Same as visualiser 0 |

The visualisers react to sound through the box's own microphone.

### State (`46`)

The reply carries 23 bytes after `04 46 55`. Decoded by changing one setting at a time and
diffing (**verified**):

| Byte | Meaning |
|---|---|
| 0 | Current view (0-5) |
| 1 | Temperature unit (0 °C, 1 °F) |
| 2 | Effect number |
| 3-5 | Lamp colour |
| 6 | Lamp level |
| 7 | Visualiser number |
| 8 | Brightness (0-100) |
| 9 | Clock 12/24 h (0/1) |
| 10-12 | Clock colour |
| 13-15 | Temperature colour |
| 16-22 | Unknown, never changed in our tests (`ff 00 00 ff ff ff 00`) |

The box stores any effect or visualiser number (even 255) without clamping, and shows
number 0's pattern for anything out of range.

### Alarms (`42`) and reminders (`53`)

`42` answers with 3 alarms of 10 bytes each: `index` `on` `hour` `minute`, then 5 bytes we did
not decode (the first looks like a repeat mode), then the volume (`32` = 50).

`53` answers once per reminder slot (10 slots), 39 bytes each: `index` `on` `month` `day`
`hour` `minute`, then the name. Names set from the Divoom app are UTF-16LE; empty slots say
`Event` in plain ASCII. We only read these, never wrote them.

## Games

The TimeBox-mini has **6 built-in games** (**verified** on camera, see `docs/games-*.jpg`):

| Game | What it is |
|---|---|
| 0 | Slot machine: "go" spins the reels |
| 1 | Dice: "go" rolls |
| 2 | Magic 8-ball: answers with "NO", a heart, a smiley and so on |
| 3 | Catch the falling stars |
| 4 | Picture scenes (an eagle, landscapes) |
| 5 | Falling-blocks stacking game |

- Start with `a0 01 N`, leave with `a0 00 00`. "Go" is `88`, the arrows and ok are `17 K`
  (down) followed by `21 K` (up).
- A game only runs while the Bluetooth connection stays open. The box leaves it the moment
  the connection drops, so a one-shot command looks like it does nothing. `tb game N`
  keeps the connection open.
- **Do not start game 6 or higher.** Trying 6-9 in a row froze our box on game 5's screen:
  it stopped answering on Bluetooth and its buttons stopped working. `tb game` refuses
  numbers above 5 unless you add `--force`.

## Full command scan

`tb scan` sends every command byte from `00` to `ff` with no data, one at a time on one
connection, and logs the reply and the state (`46`) after each. Results:

- Unknown commands get **no reply at all**, not an `AA`.
- These answered with `55` (accepted). "Data" is what came back after `55`:

| Cmd | Data back | Our reading |
|---|---|---|
| `05` | none | Radio (known) |
| `08` / `09` | `0b` | Volume set / probably volume read (it was 11) |
| `0a` | none | ? |
| `0b` | `ff` | ? |
| `10` | `c6 0f` | Little-endian 4038: most likely the battery in millivolts |
| `13` | `00` | ? |
| `18` | none | Set time (known) |
| `1b`, `1c`, `27`, `29` | none | ? |
| `30` | `30` | ? |
| `31` | `64` | 100: probably reads the brightness |
| `32` | `35` | ? (brightness replies use this number) |
| `35` | `00 00 00` | ? |
| `37` | answered as `30` with `37` | ? |
| `38` | `3b` | ? |
| `40` | `01` | Sleep timer (known) |
| `41` | `00` | Probably reads the sleep timer |
| `42` | 3 alarms | See above |
| `43` | none | Alarm (known) |
| `44` | `00` | Image (known) |
| `46` | 23 bytes | State (known) |
| `4a` | `00` | ? |
| `4b` | `01` + 12 zero bytes | ? |
| `4c`, `4d` | answered as `4c` with `4f` | ? |
| `4f` | answered as `81` | ? |
| `50` | none | ? |
| `53` | 10 reminders | See above |
| `54` | none | Probably sets a reminder (known in the evo protocol) |
| `57`, `58` | `00` | ? |
| `59` | `00 08 00` | ? |
| `68` | `00` | ? |
| `70` | `6c` | ? |
| `73` | `01` + 6 zero bytes | ? |
| `74` | answered as `32` | Brightness (known) |
| `80` | 16 zero bytes | ? |
| `81` | `01` | ? |
| `90` | `87 27 ff ff 01 0a` | Probably version information |
| `92` | `01` | ? |
| `93` | none | ? |
| `96` | `,http://dev.divoom.net/firmware/firmware.json` | The firmware update URL |
| `a0` | none | Games (known) |
| `a1` | none | ? |
| `a2` | `43` + 9 zero bytes | ? |
| `a7`, `aa`, `b2` | `00` | ? |
| `a8` | `aa` | ? |
| `ac` | `ae 00` | ? |
| `b0` | `b2 01` | ? |
| `b3` | `b5` | ? |

- `0c`, `0d`, `11`, `16`, `17`, `60`-`63`, `66`, `67` answered with an empty frame.
- Watch out: several replies (`38` → `3b`, `4c` → `4f`, `a8` → `aa`, `b3` → `b5`) are close to
  the frame's own checksum byte. Commands that expect an argument probably read the checksum
  as the argument when none is sent, so **an empty-data scan can change settings**. After our
  scan the box's own buttons no longer behaved as before, and a later game test froze it.
  Scan on a box you can afford to reset.

## Not covered

- What most of the scan's unknown commands do. The plan was to repeat the scan with one
  argument byte, but our box froze before that could run.
- Radio, sleep timer, writing alarms and reminders, and state bytes 16-22.
