import SwiftUI

/// Elektron-style parameter lock lane: pick a device + parameter, then draw a value per step.
/// Locked steps show their value; unlocked steps show the base value (dim).
struct LockPanel: View {
    @Environment(LiveStore.self) private var store
    let resolution: Double
    let firstStep: Int
    let stepsPerPage: Int
    let totalSteps: Int
    let color: Color
    @Binding var lockParam: Int

    @State private var erase = false
    @State private var dragging = false

    private var param: ParamInfo? { store.params.first { $0.i == lockParam } }
    private var lane: LockLane? {
        guard let l = store.lockLane, l.i == lockParam, l.path == store.focused?.path else { return nil }
        return l
    }

    var body: some View {
        VStack(spacing: 6) {
            header.padding(.horizontal, 8)
            HStack(spacing: 3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(param?.name ?? "—").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text("base \(lane?.baseDisplay ?? param?.display ?? "")")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(width: 92, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panel))

                laneCells
            }
            .frame(height: 120)
        }
        // No horizontal padding so the lane's columns line up with the step grid above.
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
        .onAppear(perform: prepare)
        .onChange(of: store.devices) { prepare() }
        .onChange(of: store.focused) { _, _ in
            lockParam = 1
            reload()
        }
        .onChange(of: lockParam) { reload() }
        .onChange(of: resolution) { reload() }
        .onChange(of: store.seq?.loopEnd) { reload() }
        .onChange(of: store.seq?.s) { reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("P-Locks", systemImage: "lock.fill").font(.caption.weight(.bold)).foregroundStyle(color)
            Menu {
                ForEach(store.devices) { d in
                    Button(String(repeating: "  ", count: d.depth) + d.name) { store.focusDevice(d) }
                }
            } label: {
                chip(store.focused?.name ?? "Device", icon: "dial.medium")
            }
            Menu {
                ForEach(store.params.dropFirst()) { p in
                    Button { lockParam = p.i } label: {
                        Text(p.name) + Text("  \(p.display)").foregroundStyle(.secondary)
                    }
                }
            } label: {
                chip(param?.name ?? "Parameter", icon: "slider.horizontal.3")
            }
            if let param {
                Knob(value: (lane?.base).map { norm($0, param) } ?? param.normalized, color: .gray, size: 30,
                     onBegin: { store.beginTouch("lock") },
                     onChange: { store.lockSetBase(param.i, value: value($0, param), step: resolution) },
                     onEnd: { store.endTouch("lock") })
                Text("Base").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $erase) { Label("Erase", systemImage: "eraser") }
                .toggleStyle(.button).font(.caption)
            Button(role: .destructive) { store.lockClear(lockParam, step: resolution) } label: {
                Label("Clear lane", systemImage: "trash")
            }
            .font(.caption)
            .disabled(lane?.values.contains { $0 != nil } != true)
        }
    }

    private var laneCells: some View {
        GeometryReader { geo in
            let cellW = (geo.size.width - CGFloat(stepsPerPage - 1) * 3) / CGFloat(stepsPerPage)
            HStack(spacing: 3) {
                ForEach(0..<stepsPerPage, id: \.self) { i in
                    let k = firstStep + i
                    LockCell(level: level(k), locked: lockedValue(k) != nil, display: display(k),
                             inLoop: k < totalSteps, color: color, beatStart: k % 4 == 0)
                        .frame(width: cellW)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let param, store.seq?.hasClip == true else { return }
                        if !dragging { dragging = true; store.beginTouch("lock") }
                        let i = Int(g.location.x / (cellW + 3))
                        guard (0..<stepsPerPage).contains(i) else { return }
                        let k = firstStep + i
                        guard k < totalSteps else { return }
                        if erase {
                            if lockedValue(k) != nil { store.lockSet(param.i, k: k, value: nil, step: resolution) }
                        } else {
                            let n = min(1, max(0, 1 - g.location.y / geo.size.height))
                            store.lockSet(param.i, k: k, value: value(n, param), step: resolution)
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        store.endTouch("lock")
                        // Re-read from Live once the last coalesced write has landed, for value labels.
                        Task {
                            try? await Task.sleep(for: .milliseconds(400))
                            reload()
                        }
                    }
            )
        }
    }

    private func lockedValue(_ k: Int) -> Double? {
        guard let lane, lane.values.indices.contains(k) else { return nil }
        return lane.values[k]
    }
    private func level(_ k: Int) -> Double {
        guard let param else { return 0 }
        return norm(lockedValue(k) ?? lane?.base ?? param.value, param)
    }
    private func display(_ k: Int) -> String {
        guard let lane, lane.displays.indices.contains(k), let d = lane.displays[k] else { return "" }
        return d
    }
    private func norm(_ v: Double, _ p: ParamInfo) -> Double { p.max > p.min ? (v - p.min) / (p.max - p.min) : 0 }
    private func value(_ n: Double, _ p: ParamInfo) -> Double {
        let v = p.value(fromNormalized: n)
        return p.quantized ? v.rounded() : v
    }

    private func prepare() {
        guard let seq = store.seq else { return }
        if store.watchedTrack != seq.t { store.watchTrack(seq.t); return }
        if store.focused?.t != seq.t, let first = store.devices.first { store.focusDevice(first); return }
        reload()
    }
    private func reload() {
        guard store.focused != nil, store.seq?.hasClip == true else { return }
        store.lockLoad(lockParam, step: resolution)
    }

    private func chip(_ text: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))
    }
}

private struct LockCell: View {
    let level: Double
    let locked: Bool
    let display: String
    let inLoop: Bool
    let color: Color
    let beatStart: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(beatStart ? Color(white: 0.22) : Theme.cell)
                RoundedRectangle(cornerRadius: 3)
                    .fill(locked ? color : Color.white.opacity(0.12))
                    .frame(height: max(3, geo.size.height * level))
                if locked, !display.isEmpty {
                    Text(display)
                        .font(.system(size: 8, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(2)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .opacity(inLoop ? 1 : 0.3)
    }
}

/// "Hold a step and turn knobs": locks any of the focused device's parameters on one step.
struct StepLockSheet: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let step: Int
    let resolution: Double
    let color: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.focused == nil || store.focused?.t != store.seq?.t {
                    ContentUnavailableView("Pick a device", systemImage: "dial.medium",
                                           description: Text("Choose a device on this track in the P-Locks panel first."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 14) {
                        ForEach(store.params.dropFirst()) { p in
                            let locked = store.lockStepLocks[p.i]
                            VStack(spacing: 4) {
                                Knob(value: norm(locked ?? p.value, p), color: locked != nil ? color : .gray,
                                     steps: p.quantized ? Int(p.max - p.min) : nil,
                                     onBegin: { store.beginTouch("lockstep:\(p.i)") },
                                     onChange: { n in
                                         let v = p.value(fromNormalized: n)
                                         store.lockSet(p.i, k: step, value: p.quantized ? v.rounded() : v, step: resolution)
                                     },
                                     onEnd: { store.endTouch("lockstep:\(p.i)") })
                                    .overlay(alignment: .topTrailing) {
                                        if locked != nil {
                                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(color)
                                        }
                                    }
                                    .contextMenu {
                                        Button("Remove Lock", systemImage: "lock.open") {
                                            store.lockSet(p.i, k: step, value: nil, step: resolution)
                                        }
                                    }
                                Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(locked != nil ? "locked" : p.display)
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(locked != nil ? color : .secondary)
                            }
                            .frame(width: 84)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Step \(step + 1) · \(store.focused?.name ?? "")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear Step", role: .destructive) { store.lockStepClear(step, step: resolution) }
                        .disabled(store.lockStepLocks.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { store.lockStepLoad(step, step: resolution) }
        .onDisappear { store.editingLockStep = nil }
    }

    private func norm(_ v: Double, _ p: ParamInfo) -> Double { p.max > p.min ? (v - p.min) / (p.max - p.min) : 0 }
}
