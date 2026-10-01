import Foundation
import Network
import Observation

@Observable
@MainActor
final class LiveStore {
    // Connection
    var status: LiveConnection.Status = .idle
    var hostName: String = ""
    var hasState = false
    var lastError: String?

    // Session
    var song = SongState()
    var tracks: [TrackInfo] = []
    var slots: [[SlotInfo]] = []          // indexed by regular-track index, then scene
    var scenes: [SceneInfo] = []
    var returnNames: [String] = []
    var progress: [SlotKey: Double] = [:]
    var beat: Double = 0
    var meters: [[Double]] = []           // [left, right] per track index, 0...1

    // Play (pads/keys) & sequencer
    let midi = MIDIOut()
    var instrumentTrack: Int = -1
    var instrumentIsDrum = false
    var drumPadNames: [String] = []
    var seq: SeqClip?
    var seqPos: Double = -1
    var lockLane: LockLane?
    var lockStepLocks: [Int: Double] = [:]   // param index -> value, for the step being edited

    // Devices
    var watchedTrack: Int = -1
    var devices: [DeviceInfo] = []
    var focused: FocusedDevice?
    var params: [ParamInfo] = []
    var followLive: Bool = UserDefaults.standard.bool(forKey: "followLive") {
        didSet { UserDefaults.standard.set(followLive, forKey: "followLive") }
    }

    var regularTracks: [TrackInfo] { tracks.filter { $0.kind == .track } }
    var returnTracks: [TrackInfo] { tracks.filter { $0.kind == .return } }
    var masterTrack: TrackInfo? { tracks.first { $0.kind == .master } }

    @ObservationIgnored private let conn = LiveConnection()
    @ObservationIgnored private var endpoint: NWEndpoint?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var touchUntil: [String: Date] = [:]
    @ObservationIgnored private var pending: [String: [String: Any]] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let decoder = JSONDecoder()

    init() {
        conn.onStatus = { [weak self] in self?.handleStatus($0) }
        conn.onLine = { [weak self] in self?.handle(line: $0) }
    }

    // MARK: - Connection

    func connect(to endpoint: NWEndpoint) {
        self.endpoint = endpoint
        reconnectTask?.cancel()
        conn.connect(to: endpoint)
    }

    func connect(host: String, port: UInt16 = 9001) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { return }
        UserDefaults.standard.set(host, forKey: "lastHost")
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: p))
    }

    func disconnect() {
        endpoint = nil
        reconnectTask?.cancel()
        conn.disconnect()
        status = .idle
        hasState = false
    }

    private func handleStatus(_ new: LiveConnection.Status) {
        status = new
        switch new {
        case .connected:
            lastError = nil
            // Restore device view after a reconnect.
            if watchedTrack >= 0 { send(["cmd": "watch_track", "t": watchedTrack]) }
            if let f = focused { send(["cmd": "focus_device", "t": f.t, "path": f.path]) }
            if instrumentTrack >= 0 { send(["cmd": "instrument_track", "t": instrumentTrack]) }
            if instrumentTrack >= 0 {
                send(["cmd": "seq_watch", "t": seq?.t ?? instrumentTrack, "s": seq?.s ?? -1])
            }
            if let ip = conn.remoteAddress { midi.joinMacSession(address: ip, name: hostName.isEmpty ? "Live" : hostName) }
        case .failed(let message):
            lastError = message
            scheduleReconnect()
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard let endpoint else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.endpoint == endpoint else { return }
            if case .connected = self.status { return }
            self.conn.connect(to: endpoint)
        }
    }

    // MARK: - Incoming

    private func handle(line: Data) {
        guard let env = try? decoder.decode(Envelope.self, from: line) else { return }
        do {
            switch env.type {
            case "hello":
                hostName = try decoder.decode(HelloMsg.self, from: line).host
            case "state":
                apply(try decoder.decode(StateMsg.self, from: line))
            case "slot":
                let m = try decoder.decode(SlotMsg.self, from: line)
                if slots.indices.contains(m.t), slots[m.t].indices.contains(m.s) {
                    slots[m.t][m.s] = m.slot
                }
            case "track":
                apply(track: try decoder.decode(TrackMsg.self, from: line).track)
            case "scene":
                let m = try decoder.decode(SceneMsg.self, from: line)
                if scenes.indices.contains(m.s) { scenes[m.s] = m.scene }
            case "song":
                var s = try decoder.decode(SongMsg.self, from: line).song
                if isTouching("tempo") { s.tempo = song.tempo }
                song = s
                if !song.isPlaying { progress.removeAll() }
            case "progress":
                let m = try decoder.decode(ProgressMsg.self, from: line)
                beat = m.beat
                var p: [SlotKey: Double] = [:]
                for c in m.clips where c.count == 3 {
                    p[SlotKey(t: Int(c[0]), s: Int(c[1]))] = c[2]
                }
                progress = p
            case "devices":
                let m = try decoder.decode(DevicesMsg.self, from: line)
                watchedTrack = m.t
                devices = m.devices
            case "device":
                let m = try decoder.decode(DeviceMsg.self, from: line)
                if m.t < 0 {
                    focused = nil
                    params = []
                } else {
                    focused = FocusedDevice(t: m.t, path: m.path, name: m.name, className: m.className)
                    params = m.params
                }
            case "param":
                let m = try decoder.decode(ParamMsg.self, from: line)
                guard let idx = params.firstIndex(where: { $0.i == m.i }) else { return }
                if !isTouching("p:\(m.i)") { params[idx].value = m.value }
                params[idx].display = m.display
            case "appointed":
                let m = try decoder.decode(AppointedMsg.self, from: line)
                if followLive, m.t >= 0 {
                    if m.t != watchedTrack { watchTrack(m.t) }
                    if focused?.path != m.path || focused?.t != m.t {
                        send(["cmd": "focus_device", "t": m.t, "path": m.path])
                    }
                }
            case "instrument":
                let m = try decoder.decode(InstrumentMsg.self, from: line)
                instrumentTrack = m.t
                instrumentIsDrum = m.isDrum
                drumPadNames = m.pads
            case "seq":
                let m = try decoder.decode(SeqClip.self, from: line)
                seq = m.t >= 0 ? m : nil
            case "locks":
                let m = try decoder.decode(LockLane.self, from: line)
                if lockLane == nil || (lockLane?.i == m.i && lockLane?.path == m.path) {
                    if !isTouching("lock") { lockLane = m }
                }
                if let k = editingLockStep, m.values.indices.contains(k), !isTouching("lockstep:\(m.i)") {
                    lockStepLocks[m.i] = m.values[k]
                }
            case "lockstep":
                let m = try decoder.decode(LockStepMsg.self, from: line)
                if m.k == editingLockStep {
                    lockStepLocks = Dictionary(uniqueKeysWithValues: m.locks.compactMap { k, v in Int(k).map { ($0, v) } })
                }
            case "seqpos":
                seqPos = try decoder.decode(SeqPosMsg.self, from: line).pos
            case "meters":
                meters = try decoder.decode(MetersMsg.self, from: line).levels
            case "error":
                lastError = try decoder.decode(ErrorMsg.self, from: line).message
            default:
                break
            }
        } catch {
            print("decode \(env.type) failed: \(error)")
        }
    }

    private func apply(_ m: StateMsg) {
        song = m.song
        scenes = m.scenes
        returnNames = m.returns
        tracks = m.tracks.map { var t = $0; t.slots = nil; return t }
        slots = m.tracks.filter { $0.kind == .track }.map { $0.slots ?? [] }
        progress.removeAll()
        meters = []
        hasState = true
    }

    private func apply(track new: TrackInfo) {
        guard tracks.indices.contains(new.i) else { return }
        var t = new
        let old = tracks[new.i]
        if isTouching("vol:\(t.i)") { t.volume = old.volume }
        if isTouching("pan:\(t.i)") { t.pan = old.pan }
        for (idx, _) in t.sends.enumerated() where isTouching("send:\(t.i):\(idx)") && old.sends.indices.contains(idx) {
            t.sends[idx] = old.sends[idx]
        }
        tracks[new.i] = t
    }

    // MARK: - Outgoing

    func send(_ message: [String: Any]) {
        conn.send(message)
    }

    /// Continuous controls are coalesced and sent at ~30 Hz.
    private func sendCoalesced(_ key: String, _ message: [String: Any]) {
        pending[key] = message
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while let self, !self.pending.isEmpty, !Task.isCancelled {
                let batch = self.pending
                self.pending.removeAll()
                for msg in batch.values { self.conn.send(msg) }
                try? await Task.sleep(for: .milliseconds(33))
            }
            self?.flushTask = nil
        }
    }

    // While a control is held (and briefly after), ignore Live's echoes for it.
    func beginTouch(_ key: String) { touchUntil[key] = .distantFuture }
    func endTouch(_ key: String) { touchUntil[key] = Date().addingTimeInterval(0.3) }
    private func isTouching(_ key: String) -> Bool { (touchUntil[key] ?? .distantPast) > Date() }

    // Transport
    func play() { send(["cmd": song.isPlaying ? "stop" : "play"]) }
    func stop() { send(["cmd": "stop"]) }
    func stopAll() { send(["cmd": "stop_all"]) }
    func tapTempo() { send(["cmd": "tap_tempo"]) }
    func toggleMetronome() { send(["cmd": "metronome", "on": !song.metronome]) }
    func toggleSessionRecord() { send(["cmd": "session_record", "on": !song.sessionRecord]) }
    func undo() { send(["cmd": "undo"]) }
    func redo() { send(["cmd": "redo"]) }
    func setTempo(_ bpm: Double) {
        song.tempo = min(999, max(20, bpm))
        sendCoalesced("tempo", ["cmd": "tempo", "value": song.tempo])
    }

    // Session
    func fireClip(t: Int, s: Int) { send(["cmd": "fire_clip", "t": t, "s": s]) }
    func stopClip(t: Int, s: Int) { send(["cmd": "stop_clip", "t": t, "s": s]) }
    func stopTrack(_ t: Int) { send(["cmd": "stop_track", "t": t]) }
    func fireScene(_ s: Int) { send(["cmd": "fire_scene", "s": s]) }
    func selectTrack(_ t: Int) { send(["cmd": "select_track", "t": t]) }

    // Mixer
    func toggleMute(_ t: Int) { send(["cmd": "set_track", "t": t, "mute": !tracks[t].mute]) }
    func toggleSolo(_ t: Int) { send(["cmd": "set_track", "t": t, "solo": !tracks[t].solo]) }
    func toggleArm(_ t: Int) { send(["cmd": "set_track", "t": t, "arm": !tracks[t].arm]) }
    func toggleFold(_ t: Int) { send(["cmd": "set_track", "t": t, "fold": !tracks[t].isFolded]) }

    func setVolume(_ t: Int, _ v: Double) {
        tracks[t].volume = v
        sendCoalesced("vol:\(t)", ["cmd": "set_track", "t": t, "volume": v])
    }
    func setPan(_ t: Int, _ v: Double) {
        tracks[t].pan = v
        sendCoalesced("pan:\(t)", ["cmd": "set_track", "t": t, "pan": v])
    }
    func setSend(_ t: Int, _ idx: Int, _ v: Double) {
        guard tracks[t].sends.indices.contains(idx) else { return }
        tracks[t].sends[idx] = v
        sendCoalesced("send:\(t):\(idx)", ["cmd": "set_track", "t": t, "send": idx, "value": v])
    }

    // Devices
    func watchTrack(_ t: Int) {
        watchedTrack = t
        devices = []
        send(["cmd": "watch_track", "t": t])
    }
    func focusDevice(_ d: DeviceInfo) {
        guard watchedTrack >= 0 else { return }
        send(["cmd": "focus_device", "t": watchedTrack, "path": d.path])
        if followLive { send(["cmd": "select_device", "t": watchedTrack, "path": d.path]) }
    }
    // Play & sequencer
    var midiTracks: [TrackInfo] { regularTracks.filter { $0.midi } }

    func selectInstrument(_ t: Int) {
        instrumentTrack = t
        midi.allNotesOff()
        send(["cmd": "instrument_track", "t": t])
    }
    func setScale(root: Int? = nil, name: String? = nil) {
        var msg: [String: Any] = ["cmd": "set_scale"]
        if let root { msg["root"] = root; song.rootNote = root }
        if let name {
            msg["name"] = name
            song.scaleName = name
            if let s = Music.scales.first(where: { $0.name == name }) { song.scaleIntervals = s.intervals }
        }
        send(msg)
    }
    func seqWatch(t: Int, s: Int = -1) {
        send(["cmd": "seq_watch", "t": t, "s": s])
    }
    func seqToggle(pitch: Int, start: Double, step: Double, velocity: Int, clipLength: Double) {
        // Optimistic update so the grid responds instantly; Live's notes message replaces it.
        if var clip = seq {
            if clip.hasNote(pitch: pitch, from: start, span: step) {
                clip.notes.removeAll { Int($0[0]) == pitch && $0[1] >= start - 0.001 && $0[1] < start + step - 0.001 }
            } else {
                clip.notes.append([Double(pitch), start, step, Double(velocity), 0])
                if !clip.hasClip { clip.hasClip = true; clip.loopStart = 0; clip.loopEnd = clipLength }
            }
            seq = clip
        }
        send(["cmd": "seq_toggle", "pitch": pitch, "start": start, "duration": step,
              "velocity": velocity, "clipLength": clipLength])
    }
    // P-locks: stored as the sequencer clip's automation. Commands name the device explicitly.
    @ObservationIgnored var editingLockStep: Int?

    private func lockCmd(_ cmd: String, _ i: Int, step: Double, extra: [String: Any] = [:]) -> [String: Any]? {
        guard let f = focused else { return nil }
        var m: [String: Any] = ["cmd": cmd, "t": f.t, "path": f.path, "i": i, "step": step]
        m.merge(extra) { $1 }
        return m
    }
    func lockLoad(_ i: Int, step: Double) {
        if lockLane?.i != i || lockLane?.path != focused?.path { lockLane = nil }
        if let m = lockCmd("lock_lane", i, step: step) { send(m) }
    }
    func lockSet(_ i: Int, k: Int, value: Double?, step: Double) {
        if var lane = lockLane, lane.i == i, lane.values.indices.contains(k) {
            lane.values[k] = value
            lane.displays[k] = value == nil ? nil : ""
            lockLane = lane
        }
        if editingLockStep == k { lockStepLocks[i] = value }
        if let m = lockCmd("lock_set", i, step: step, extra: ["k": k, "value": value ?? NSNull()]) {
            sendCoalesced("lock:\(i):\(k)", m)
        }
    }
    func lockSetBase(_ i: Int, value: Double, step: Double) {
        lockLane?.base = value
        if let m = lockCmd("lock_base", i, step: step, extra: ["value": value]) { sendCoalesced("lockbase:\(i)", m) }
    }
    func lockClear(_ i: Int, step: Double) {
        if let m = lockCmd("lock_clear", i, step: step) { send(m) }
    }
    func lockStepLoad(_ k: Int, step: Double) {
        editingLockStep = k
        lockStepLocks = [:]
        guard let f = focused else { return }
        send(["cmd": "lock_step", "t": f.t, "path": f.path, "k": k, "step": step])
    }
    func lockStepClear(_ k: Int, step: Double) {
        for i in lockStepLocks.keys { lockSet(i, k: k, value: nil, step: step) }
        lockStepLocks = [:]
    }

    func seqClearRow(pitch: Int) { send(["cmd": "seq_clear_row", "pitch": pitch]) }
    func seqSetLength(_ beats: Double) { send(["cmd": "seq_length", "length": beats]) }
    func seqDouble() { send(["cmd": "seq_double"]) }

    /// Toggle a top-level device from the mixer's effects rack.
    func toggleTrackDevice(t: Int, index: Int) {
        guard tracks.indices.contains(t), tracks[t].devices.indices.contains(index) else { return }
        tracks[t].devices[index].isActive.toggle()
        send(["cmd": "toggle_device", "t": t, "path": [index]])
    }
    /// Jump from the mixer to a device's parameters.
    func openDevice(t: Int, index: Int) {
        watchTrack(t)
        send(["cmd": "focus_device", "t": t, "path": [index]])
    }
    func toggleDevice(_ d: DeviceInfo) {
        guard watchedTrack >= 0 else { return }
        send(["cmd": "toggle_device", "t": watchedTrack, "path": d.path])
    }
    func setParam(_ i: Int, _ value: Double) {
        guard let idx = params.firstIndex(where: { $0.i == i }) else { return }
        var v = min(params[idx].max, max(params[idx].min, value))
        if params[idx].quantized { v = v.rounded() }
        params[idx].value = v
        sendCoalesced("p:\(i)", ["cmd": "set_param", "i": i, "value": v])
    }
}
