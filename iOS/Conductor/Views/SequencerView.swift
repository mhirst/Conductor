import SwiftUI

/// Push-style step sequencer editing the selected clip's notes in Live.
/// Drum tracks show one lane per pad; melodic tracks show one row per scale note.
struct SequencerView: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var vSize

    @AppStorage("seqResolution") private var resolution = 0.25     // beats per step
    @AppStorage("seqNewClipBars") private var newClipBars = 1
    @AppStorage("seqFollow") private var follow = true
    @AppStorage("keyOctave") private var octave = 2
    @AppStorage("keyInKey") private var inKey = true
    @AppStorage("drumOffset") private var drumOffset = 36
    @AppStorage("velocity") private var velocity = 100.0

    @State private var page = 0
    @AppStorage("seqShowLocks") private var showLocks = false
    @State private var lockParam = 1
    @State private var lockStepEdit: StepRef?

    struct StepRef: Identifiable { let step: Int; var id: Int { step } }

    /// iPhone portrait shows half a bar per page so steps stay finger-sized.
    private var stepsPerPage: Int { Layout.isPhone && vSize != .compact ? 8 : 16 }

    private var track: TrackInfo? {
        store.tracks.indices.contains(store.instrumentTrack) ? store.tracks[store.instrumentTrack] : nil
    }
    private var trackColor: Color { track.map { Color(live: $0.color) } ?? Theme.accent }
    private var clipLength: Double {
        if let seq = store.seq, seq.hasClip { return max(resolution, seq.length) }
        return Double(newClipBars) * 4
    }
    private var loopStart: Double { store.seq?.hasClip == true ? store.seq!.loopStart : 0 }
    private var pageCount: Int { max(1, Int(ceil(clipLength / (Double(stepsPerPage) * resolution) - 0.0001))) }
    private var playStep: Int? {
        guard store.seqPos >= 0 else { return nil }
        return Int((store.seqPos - loopStart) / resolution)
    }

    /// Rows top-to-bottom (highest pitch first).
    private var rows: [(pitch: Int, label: String)] {
        if store.instrumentIsDrum {
            let filled = store.drumPadNames.enumerated().filter { !$0.element.isEmpty }
            if !filled.isEmpty {
                return filled.prefix(32).map { ($0.offset, $0.element) }.reversed()
            }
        }
        if store.instrumentIsDrum {
            return (drumOffset..<min(128, drumOffset + 16)).map { ($0, Music.name($0)) }.reversed()
        }
        let count = Layout.isPhone ? (vSize == .compact ? 8 : 12) : (sizeClass == .regular ? 14 : 10)
        let layout = KeyLayout(root: store.song.rootNote, intervals: store.song.scaleIntervals, inKey: inKey,
                               kind: .sequential, octave: octave, columns: 8)
        let notes = inKey ? layout.scaleNotes(count: count, from: octave)
                          : Array(((octave + 2) * 12 + store.song.rootNote)..<min(128, (octave + 2) * 12 + store.song.rootNote + count))
        return notes.map { ($0, Music.name($0)) }.reversed()
    }

    var body: some View {
        VStack(spacing: 8) {
            InstrumentTrackPicker()
            controls
            grid
            if showLocks, store.seq?.hasClip == true {
                LockPanel(resolution: resolution, firstStep: page * stepsPerPage, stepsPerPage: stepsPerPage,
                          totalSteps: Int((clipLength / resolution).rounded(.up)), color: trackColor,
                          lockParam: $lockParam)
            }
            pageBar
        }
        .padding(8)
        .onAppear {
            if store.instrumentTrack < 0, let first = store.midiTracks.first { store.selectInstrument(first.i) }
            if store.instrumentTrack >= 0, store.seq?.t != store.instrumentTrack { store.seqWatch(t: store.instrumentTrack) }
        }
        .onChange(of: store.instrumentTrack) { _, t in
            page = 0
            if t >= 0 { store.seqWatch(t: t) }
        }
        .onChange(of: playStep) { _, step in
            guard follow, let step, step >= 0 else { return }
            let p = step / stepsPerPage
            if p != page, p < pageCount { page = p }
        }
        .onChange(of: pageCount) { _, n in if page >= n { page = n - 1 } }
        .sheet(item: $lockStepEdit) { ref in
            StepLockSheet(step: ref.step, resolution: resolution, color: trackColor)
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if Layout.isPhone {
            ScrollView(.horizontal, showsIndicators: false) { controlsRow }
        } else {
            controlsRow
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            clipMenu

            Menu {
                ForEach([1, 2, 4, 8], id: \.self) { bars in
                    Button("\(bars) bar\(bars == 1 ? "" : "s")") {
                        if store.seq?.hasClip == true { store.seqSetLength(Double(bars) * 4) } else { newClipBars = bars }
                    }
                }
            } label: {
                Label(lengthLabel, systemImage: "ruler").font(.caption.weight(.semibold))
            }

            Button("×2") { store.seqDouble() }
                .font(.caption.weight(.bold))
                .disabled(store.seq?.hasClip != true)

            Picker("Step", selection: $resolution) {
                Text("1/8").tag(0.5)
                Text("1/16").tag(0.25)
                Text("1/32").tag(0.125)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            if !store.instrumentIsDrum {
                HStack(spacing: 2) {
                    Button { octave = max(-1, octave - 1) } label: { Image(systemName: "chevron.down").frame(width: 28, height: 28) }
                    Text("Oct \(octave)").font(.caption.monospacedDigit().weight(.semibold))
                    Button { octave = min(7, octave + 1) } label: { Image(systemName: "chevron.up").frame(width: 28, height: 28) }
                }
                .buttonStyle(.plain)
                ScaleMenus()
            }

            Toggle(isOn: $showLocks) { Label("Locks", systemImage: "lock") }
                .toggleStyle(.button)
                .font(.caption.weight(.semibold))
                .disabled(store.seq?.hasClip != true)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text("Vel").font(.caption).foregroundStyle(.secondary)
                Slider(value: $velocity, in: 1...127).frame(width: 80)
                Text("\(Int(velocity))").font(.caption.monospacedDigit()).frame(width: 26)
            }
        }
    }

    private var lengthLabel: String {
        let beats = clipLength
        let bars = beats / 4
        return bars == bars.rounded() ? "\(Int(bars)) bar\(bars == 1 ? "" : "s")" : String(format: "%.2g beats", beats)
    }

    private var clipMenu: some View {
        let t = store.instrumentTrack
        let slots = store.slots.indices.contains(t) ? store.slots[t] : []
        let current = store.seq?.s ?? -1
        return Menu {
            ForEach(slots.indices, id: \.self) { s in
                Button {
                    page = 0
                    store.seqWatch(t: t, s: s)
                } label: {
                    let name = slots[s].hasClip ? (slots[s].name.isEmpty ? "Clip" : slots[s].name) : "Empty — new clip"
                    Label("\(s + 1). \(name)", systemImage: s == current ? "checkmark" : (slots[s].hasClip ? "rectangle.fill" : "rectangle.dashed"))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(trackColor).frame(width: 8, height: 8)
                Text(clipTitle).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))
        }
    }

    private var clipTitle: String {
        guard let seq = store.seq else { return "No clip" }
        if seq.isAudio { return "Slot \(seq.s + 1): audio clip" }
        if !seq.hasClip { return "Slot \(seq.s + 1): empty — tap a step" }
        return "Slot \(seq.s + 1): \(seq.name.isEmpty ? "Clip" : seq.name)"
    }

    // MARK: Grid

    private var grid: some View {
        let rows = rows
        let seq = store.seq
        let firstStep = page * stepsPerPage
        let totalSteps = Int((clipLength / resolution).rounded(.up))
        return ScrollView(.vertical) {
            VStack(spacing: 3) {
                ForEach(rows, id: \.pitch) { row in
                    HStack(spacing: 3) {
                        RowLabel(label: row.label, isRoot: !store.instrumentIsDrum && (row.pitch - store.song.rootNote) % 12 == 0,
                                 color: trackColor)
                            .onTapGesture { audition(row.pitch) }
                            .contextMenu {
                                Button("Clear Row", systemImage: "trash", role: .destructive) { store.seqClearRow(pitch: row.pitch) }
                            }
                        ForEach(0..<stepsPerPage, id: \.self) { i in
                            let step = firstStep + i
                            let start = loopStart + Double(step) * resolution
                            let on = seq?.hasNote(pitch: row.pitch, from: start, span: resolution) ?? false
                            StepCell(on: on, color: trackColor, inLoop: step < totalSteps,
                                     playhead: playStep == step, beatStart: step % 4 == 0,
                                     locked: showLocks && on && lockedStep(step))
                                .onLongPressGesture(minimumDuration: 0.35) {
                                    // Elektron-style: hold a step to lock parameters on it.
                                    guard seq?.hasClip == true, step < totalSteps else { return }
                                    showLocks = true
                                    lockStepEdit = StepRef(step: step)
                                }
                                .onTapGesture {
                                    guard step < totalSteps || seq?.hasClip != true, seq?.isAudio != true else { return }
                                    store.seqToggle(pitch: row.pitch, start: start, step: resolution,
                                                    velocity: Int(velocity), clipLength: clipLength)
                                }
                        }
                    }
                    .frame(height: Layout.isPhone ? 34 : (sizeClass == .regular ? 38 : 30))
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private var pageBar: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $follow) { Label("Follow", systemImage: "arrow.right.to.line") }
                .toggleStyle(.button)
                .font(.caption)
            Spacer()
            ForEach(0..<pageCount, id: \.self) { p in
                let playing = playStep.map { $0 / stepsPerPage == p } ?? false
                Button { page = p; follow = false } label: {
                    Text("\(p + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 28)
                        .foregroundStyle(p == page ? .black : .white)
                        .background(RoundedRectangle(cornerRadius: 5).fill(p == page ? trackColor : Theme.cell))
                        .overlay(alignment: .bottom) {
                            if playing { Rectangle().fill(Theme.play).frame(height: 3) }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(store.seqPos >= 0 ? "▶︎ step \((playStep ?? 0) + 1)" : "stopped")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
        }
    }

    private func lockedStep(_ step: Int) -> Bool {
        guard let lane = store.lockLane, lane.values.indices.contains(step) else { return false }
        return lane.values[step] != nil
    }

    private func audition(_ pitch: Int) {
        store.midi.noteOn(pitch, velocity: Int(velocity))
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            store.midi.noteOff(pitch)
        }
    }
}

private struct RowLabel: View {
    let label: String
    let isRoot: Bool
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: Layout.rowLabelWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .foregroundStyle(isRoot ? .black : .white.opacity(0.85))
            .background(RoundedRectangle(cornerRadius: 4).fill(isRoot ? color : Theme.panel))
            .contentShape(Rectangle())
    }
}

private struct StepCell: View {
    let on: Bool
    let color: Color
    let inLoop: Bool
    let playhead: Bool
    let beatStart: Bool
    var locked = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(on ? color : (beatStart ? Color(white: 0.24) : Theme.cell))
            .opacity(inLoop ? 1 : 0.3)
            .overlay {
                if playhead {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(on ? 0.45 : 0.18))
                }
            }
            .overlay(alignment: .topTrailing) {
                if locked {
                    Circle().fill(Color.white.opacity(0.85)).frame(width: 5, height: 5).padding(3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }
}
