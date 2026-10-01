# Conductor

iOS remote for Ableton Live (in the spirit of touchAble): clip launching, mixer, and device/VST parameter control.

## Layout

```
RemoteScript/
├── Conductor/          Live MIDI Remote Script (Python 3, raw c_instance API — no _Framework)
│   ├── __init__.py
│   └── Conductor.py    TCP server + Live Object Model bridge
├── install.sh          Symlinks Conductor/ into ~/Music/Ableton/User Library/Remote Scripts
└── dev/fake_live.py    Runs the real script against a simulated Live set (no Ableton needed)
iOS/
├── project.yml         XcodeGen spec (iOS 18+, SwiftUI) — run `xcodegen generate` after adding files
└── Conductor/
    ├── App/            ConductorApp
    ├── Net/            LiveConnection (NWConnection, NDJSON), ServiceBrowser (Bonjour)
    ├── Model/          Models (wire types), LiveStore (@Observable state + intents)
    └── Views/          RootView/Transport/Connect, SessionView, MixerView, DevicesView, PlayView (drums/keys),
                        SequencerView (steps), PadSurface (UIKit multi-touch grid + touch strips), Controls
```

## Protocol

Newline-delimited JSON over TCP port 9001, advertised via Bonjour as `_conductor._tcp` (the script spawns `/usr/bin/dns-sd`).

- Client → server: `{"cmd": ...}` — `fire_clip`, `stop_track`, `fire_scene`, `set_track` (volume/pan/send/mute/solo/arm/fold), `watch_track`, `focus_device`, `set_param`, `toggle_device`, transport cmds.
- Server → client: `state` (full dump on connect / structure change), then incremental `track`, `slot`, `scene`, `song`, `progress` (clip playheads), `meters`, `devices` (watched track's tree), `device` + `param` (focused device), `appointed` (Live's blue-hand device).
- Push-style: `instrument_track` (select + implicit-arm a MIDI track; replies `instrument` with Drum Rack pad names), `set_scale` (Live 12 song root/scale), `seq_watch`/`seq_toggle`/`seq_length`/`seq_double`/`seq_clear_row` (edit clip notes; replies `seq`, plus `seqpos` playhead each tick). Note arrays are numeric: `[pitch, start, dur, vel, mute(0/1)]`.
- Track index `t` is flat: regular tracks, then returns, then master. Device `path` is `[device, chain, device, chain, ...]`.

## Key design points

- All Live API access happens in `update_display()` (~10 Hz). Listeners only mark keys dirty; the tick coalesces and broadcasts. So app→Live latency is up to ~100 ms.
- The app coalesces continuous controls (faders/knobs) to ~30 Hz and ignores Live's echoes for a control while it's held (`beginTouch`/`endTouch`).
- **Pads/keys don't use the TCP protocol** — `MIDIOut` sends CoreMIDI over an RTP-MIDI network session so note timing isn't bound to the script tick. The Mac needs an **RTP** session (not "Network MIDI 2") in Audio MIDI Setup › MIDI Studio › globe button, and "Track" on for that input in Live.
  - The app finds the Mac's session via Bonjour `_apple-midi._udp`, matched to Live's IP. macOS may not advertise the session (blank Network Name), so after 2.5 s it falls back to the port in the MIDI sheet (`midiPort`, default 5004).
  - Network.framework formats IPs as `192.168.1.5%en0`; strip the `%iface` before handing them to CoreMIDI.
  - Simulator: its own MIDIServer grabs UDP 5004, so put the Mac's RTP session on another port (e.g. 5008) and set `midiPort` to match (`xcrun simctl spawn booted defaults write com.mhirst.conductor midiPort -int 5008`).
- **P-locks** (Elektron-style) are the sequencer clip's automation envelopes: `lock_*` commands rewrite a parameter's envelope as constant steps (`insert_step`) — locked steps hold their value, others hold the lane's base — then `re_enable_automation()`. Reading back samples `value_at_time` mid-step; the base is kept in memory and, after a reload, guessed as the most common step value. Lock commands carry the device's `t`/`path` explicitly because the script's focused device is shared by all connected clients.
- Script hot reload: send `{"cmd":"dev_reload"}` on port 9001 — the `_Host` wrapper in `__init__.py` re-imports `Conductor.py` without restarting Live.
- Faders/knobs use relative drags (never jump); XY pad is absolute.

## Dev loop

```
python3 RemoteScript/dev/fake_live.py      # fake Live on :9001
cd iOS && xcodegen generate && open Conductor.xcodeproj
```

In real Live, after editing the script: re-select the control surface in Settings (or restart Live). Logs go to `~/Library/Preferences/Ableton/Live */Log.txt` (grep `[Conductor]`).
