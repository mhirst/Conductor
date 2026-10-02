import SwiftUI

enum PlayMode: String, CaseIterable { case drums = "Drums", keys = "Keys" }

struct PlayView: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    @AppStorage("playMode") private var mode: PlayMode = .drums
    @AppStorage("keyOctave") private var octave = 2
    @AppStorage("keyInKey") private var inKey = true
    @AppStorage("keyLayout") private var layoutKind: KeyLayout.Kind = .fourths
    @AppStorage("drumOffset") private var drumOffset = 36
    @AppStorage("drum64") private var drum64 = false
    @AppStorage("velocity") private var velocity = 100.0
    @AppStorage("velocityByPosition") private var velocityByPosition = false

    @State private var held: [Int: Int] = [:]      // cell -> note sounding
    @State private var showMIDIHelp = false
    @State private var showSettings = false
    @State private var showBrowser = false
    @State private var phoneKeyRows = 8              // iPhone: as many rows as keep the pads square

    private var track: TrackInfo? {
        store.tracks.indices.contains(store.instrumentTrack) ? store.tracks[store.instrumentTrack] : nil
    }
    private var trackColor: Color { track.map { Color(live: $0.color) } ?? Theme.accent }

    private var keyLayout: KeyLayout {
        KeyLayout(root: store.song.rootNote, intervals: store.song.scaleIntervals, inKey: inKey,
                  kind: layoutKind, octave: octave, columns: 8)
    }

    private var rows: Int {
        if mode == .drums { return drum64 ? 8 : 4 }
        if Layout.isPhone { return phoneKeyRows }
        return sizeClass == .regular ? 8 : 5
    }
    private var cols: Int { mode == .drums ? (drum64 ? 8 : 4) : 8 }

    var body: some View {
        VStack(spacing: 8) {
            InstrumentTrackPicker()
            if Layout.isPhone { phoneToolbar } else { toolbar }
            HStack(spacing: Layout.isPhone ? 6 : 8) {
                TouchStrip(mode: .pitchBend, color: trackColor) { store.midi.pitchBend($0) }
                padGrid
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        guard Layout.isPhone, size.width > 0 else { return }
                        let cell = (size.width - 7 * 4) / 8
                        let fit = Int((size.height + 4) / (cell + 4))
                        let n = min(8, max(3, fit))
                        if n != phoneKeyRows { releaseAll(); phoneKeyRows = n }
                    }
                TouchStrip(mode: .modulation, color: trackColor) { store.midi.controlChange(1, $0) }
            }
        }
        .padding(Layout.isPhone ? 6 : 8)
        .onAppear {
            if store.instrumentTrack < 0, let first = store.midiTracks.first { store.selectInstrument(first.i) }
            store.midi.refresh()
            syncModeToTrack()
        }
        // Like Push: drum racks open in Drums, everything else in Keys.
        .onChange(of: store.instrumentIsDrum) { syncModeToTrack() }
        .onChange(of: store.instrumentTrack) { syncModeToTrack() }
        .onDisappear { releaseAll() }
        .sheet(isPresented: $showMIDIHelp) { MIDISetupSheet() }
        .sheet(isPresented: $showBrowser) { BrowserView(inSheet: true) }
        .sheet(isPresented: $showSettings) {
            PlaySettingsSheet(mode: mode)
                .presentationDetents([.medium, .large])
        }
    }

    /// iPhone: one row — mode, bank/octave, arm, settings, MIDI. The rest lives in the settings sheet.
    private var phoneToolbar: some View {
        HStack(spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(PlayMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 128)
            .onChange(of: mode) { releaseAll() }

            if mode == .drums {
                stepper(label: Music.name(drumOffset),
                        down: { drumOffset = max(0, drumOffset - (drum64 ? 4 : 16)) },
                        up: { drumOffset = min(128 - rows * cols, drumOffset + (drum64 ? 4 : 16)) })
            } else {
                stepper(label: "Oct \(octave)", down: { octave = max(-1, octave - 1) }, up: { octave = min(7, octave + 1) })
            }

            Spacer(minLength: 0)

            if let track, track.canArm {
                ToggleChip(label: "", systemImage: "record.circle", isOn: track.arm, onColor: Theme.record) {
                    store.toggleArm(track.i)
                }
                .frame(width: 40)
            }
            Button { showBrowser = true } label: {
                Image(systemName: "folder").frame(width: 32, height: 32)
            }
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32)
            }
            Button { showMIDIHelp = true } label: {
                Image(systemName: "pianokeys")
                    .foregroundStyle(store.midi.destinations.isEmpty ? Theme.record : Theme.play)
                    .frame(width: 32, height: 32)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $mode) {
                ForEach(PlayMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .onChange(of: mode) { releaseAll() }

            if mode == .drums {
                stepper(label: Music.name(drumOffset),
                        down: { drumOffset = max(0, drumOffset - (drum64 ? 4 : 16)) },
                        up: { drumOffset = min(128 - rows * cols, drumOffset + (drum64 ? 4 : 16)) })
                Picker("Pads", selection: $drum64) {
                    Text("16").tag(false)
                    Text("64").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
            } else {
                stepper(label: "Oct \(octave)", down: { octave = max(-1, octave - 1) }, up: { octave = min(7, octave + 1) })
                ScaleMenus()
                Toggle("In Key", isOn: $inKey).toggleStyle(.button).font(.caption.weight(.semibold))
                Menu(layoutKind.rawValue) {
                    ForEach(KeyLayout.Kind.allCases, id: \.self) { k in Button(k.rawValue) { layoutKind = k } }
                }
                .font(.caption.weight(.semibold))
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Button { velocityByPosition.toggle() } label: {
                    Image(systemName: velocityByPosition ? "hand.point.up.braille.fill" : "hand.point.up.braille")
                }
                .help("Velocity from touch position")
                Slider(value: $velocity, in: 1...127).frame(width: 90).disabled(velocityByPosition)
                Text(velocityByPosition ? "Pos" : "\(Int(velocity))")
                    .font(.caption.monospacedDigit()).frame(width: 28)
            }

            if let track, track.canArm {
                ToggleChip(label: "", systemImage: "record.circle", isOn: track.arm, onColor: Theme.record) {
                    store.toggleArm(track.i)
                }
                .frame(width: 44)
            }

            Button { showBrowser = true } label: {
                Label("Browse", systemImage: "folder")
            }
            .font(.caption.weight(.semibold))

            Button { showMIDIHelp = true } label: {
                Image(systemName: "pianokeys")
                    .foregroundStyle(store.midi.destinations.isEmpty ? Theme.record : Theme.play)
            }
        }
    }

    private func stepper(label: String, down: @escaping () -> Void, up: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Button(action: { releaseAll(); down() }) { Image(systemName: "chevron.down").frame(width: 30, height: 30) }
            Text(label).font(.caption.monospacedDigit().weight(.semibold)).frame(minWidth: 44)
            Button(action: { releaseAll(); up() }) { Image(systemName: "chevron.up").frame(width: 30, height: 30) }
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))
    }

    // MARK: Pads

    private var padGrid: some View {
        let rows = rows, cols = cols
        let sounding = Set(held.values)
        return ZStack {
            VStack(spacing: 4) {
                ForEach((0..<rows).reversed(), id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<cols, id: \.self) { c in
                            let note = note(row: r, col: c)
                            PadCell(label: label(for: note), color: color(for: note),
                                    lit: sounding.contains(note), dim: isDimmed(note))
                        }
                    }
                }
            }
            MultiTouchGrid(rows: rows, cols: cols, onDown: { cell, pos in
                let n = note(row: cell / cols, col: cell % cols)
                guard (0...127).contains(n) else { return }
                if let old = held[cell] { store.midi.noteOff(old) }
                held[cell] = n
                store.midi.noteOn(n, velocity: velocityByPosition ? Int(30 + pos * 97) : Int(velocity))
            }, onUp: { cell in
                if let n = held.removeValue(forKey: cell) { store.midi.noteOff(n) }
            })
        }
    }

    private func note(row: Int, col: Int) -> Int {
        mode == .drums ? drumOffset + row * cols + col : keyLayout.note(row: row, col: col)
    }

    private func label(for note: Int) -> String {
        if mode == .drums {
            let name = store.drumPadNames.indices.contains(note) ? store.drumPadNames[note] : ""
            return name.isEmpty ? Music.name(note) : name
        }
        return keyLayout.isRoot(note) || !inKey ? Music.name(note) : ""
    }

    private func isDimmed(_ note: Int) -> Bool {
        if mode == .drums {
            return store.instrumentIsDrum && (store.drumPadNames.indices.contains(note) ? store.drumPadNames[note].isEmpty : true)
        }
        return !inKey && !keyLayout.inScale(note)
    }

    private func color(for note: Int) -> Color {
        if mode == .drums { return trackColor }
        if keyLayout.isRoot(note) { return trackColor }
        return keyLayout.inScale(note) ? Color(white: 0.78) : Color(white: 0.28)
    }

    private func syncModeToTrack() {
        guard store.instrumentTrack >= 0 else { return }
        mode = store.instrumentIsDrum ? .drums : .keys
    }

    private func releaseAll() {
        for n in held.values { store.midi.noteOff(n) }
        held.removeAll()
    }
}

private struct PadCell: View {
    let label: String
    let color: Color
    let lit: Bool
    let dim: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(lit ? Theme.play : color.opacity(dim ? 0.18 : 0.75))
            .overlay(alignment: .bottomLeading) {
                // Drum Rack pad names run long ("Hihat Open Stick 90s"): wrap rather than truncate.
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(dim ? 0.0 : 0.75))
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(lit ? 0.9 : 0), lineWidth: 2))
            .animation(.easeOut(duration: 0.06), value: lit)
    }
}

/// Chips for choosing which MIDI track the pads/keys/sequencer target (selected + auto-armed in Live).
struct InstrumentTrackPicker: View {
    @Environment(LiveStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.midiTracks) { track in
                    let selected = track.i == store.instrumentTrack
                    Text(track.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .foregroundStyle(selected ? .black : .white.opacity(0.85))
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color(live: track.color) : Theme.cell))
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(live: track.color)).frame(height: 2) }
                        .onTapGesture { store.selectInstrument(track.i) }
                }
                if store.midiTracks.isEmpty {
                    Text("No MIDI tracks in this set").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Root + scale menus, synced with Live 12's song scale.
struct ScaleMenus: View {
    @Environment(LiveStore.self) private var store

    var body: some View {
        Menu(Music.noteNames[store.song.rootNote % 12]) {
            ForEach(0..<12, id: \.self) { r in Button(Music.noteNames[r]) { store.setScale(root: r) } }
        }
        .font(.caption.weight(.semibold))
        Menu(store.song.scaleName) {
            ForEach(Music.scales, id: \.name) { s in Button(s.name) { store.setScale(name: s.name) } }
        }
        .font(.caption.weight(.semibold))
    }
}

struct MIDISetupSheet: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("midiPort") private var midiPort = 5004

    var body: some View {
        NavigationStack {
            List {
                Section("Why") {
                    Text("Pads and keys send real MIDI to your Mac for tight timing, instead of going through the remote script.")
                }
                Section("One-time setup on the Mac") {
                    Text("1. Open **Audio MIDI Setup** › Window › Show MIDI Studio › double-click **Network**.")
                    Text("2. Add a session with **+**, tick it enabled, set “Who may connect” to **Anyone**. Pick **RTP**, not Network MIDI 2.")
                    Text("3. In Live: Settings › Link, Tempo & MIDI › MIDI Ports › turn on **Track** for input “Network Session 1”.")
                    Text("Conductor joins the session automatically when it connects. A USB cable with the iPad enabled in Audio MIDI Setup works too.")
                }
                Section {
                    HStack {
                        Text("Mac session port")
                        Spacer()
                        TextField("5004", value: $midiPort, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Button("Reconnect") { store.midi.reconnect(port: midiPort) }
                    }
                } footer: {
                    Text("Used if the Mac's session isn't found automatically. It's the Port shown for your RTP session in MIDI Network Setup.")
                }
                Section("MIDI destinations seen by this device") {
                    if store.midi.destinations.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(store.midi.destinations, id: \.self) { Text($0) }
                    ForEach(store.midi.networkConnections, id: \.self) { Label($0, systemImage: "network") }
                }
            }
            .navigationTitle("MIDI")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { store.midi.refresh() }
        }
    }
}

/// iPhone Play settings that don't fit in the toolbar.
struct PlaySettingsSheet: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let mode: PlayMode

    @AppStorage("keyInKey") private var inKey = true
    @AppStorage("keyLayout") private var layoutKind: KeyLayout.Kind = .fourths
    @AppStorage("drum64") private var drum64 = false
    @AppStorage("velocity") private var velocity = 100.0
    @AppStorage("velocityByPosition") private var velocityByPosition = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Velocity") {
                    Toggle("From touch position", isOn: $velocityByPosition)
                    HStack {
                        Slider(value: $velocity, in: 1...127)
                        Text("\(Int(velocity))").monospacedDigit().frame(width: 36)
                    }
                    .disabled(velocityByPosition)
                }
                if mode == .drums {
                    Section("Drums") {
                        Picker("Pads", selection: $drum64) {
                            Text("16").tag(false)
                            Text("64").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                } else {
                    Section("Keys") {
                        Picker("Root", selection: Binding(get: { store.song.rootNote % 12 },
                                                          set: { store.setScale(root: $0) })) {
                            ForEach(0..<12, id: \.self) { Text(Music.noteNames[$0]).tag($0) }
                        }
                        Picker("Scale", selection: Binding(get: { store.song.scaleName },
                                                           set: { store.setScale(name: $0) })) {
                            ForEach(Music.scales, id: \.name) { Text($0.name).tag($0.name) }
                        }
                        Toggle("In Key", isOn: $inKey)
                        Picker("Layout", selection: $layoutKind) {
                            ForEach(KeyLayout.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                }
            }
            .navigationTitle("Play Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
