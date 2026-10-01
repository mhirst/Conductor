import SwiftUI

struct DevicesView: View {
    @Environment(LiveStore.self) private var store
    @AppStorage("deviceMode") private var mode: Mode = .knobs
    @State private var showBrowser = false

    enum Mode: String, CaseIterable { case knobs = "Knobs", xy = "XY" }

    var body: some View {
        VStack(spacing: 6) {
            TrackPicker()
            DeviceChain()
            Group {
            if Layout.isPhone {
                // iPhone: device name on its own line, controls under it.
                VStack(alignment: .leading, spacing: 6) {
                    deviceTitle
                    HStack {
                        followToggle
                        Button { showBrowser = true } label: { Image(systemName: "books.vertical") }
                        Spacer()
                        modePicker
                    }
                }
            } else {
                HStack {
                    deviceTitle
                    Spacer()
                    followToggle
                    Button { showBrowser = true } label: { Label("Browse", systemImage: "books.vertical") }
                        .font(.caption)
                    modePicker
                }
            }
            }
            .padding(.horizontal, 6)

            Group {
                switch mode {
                case .knobs: ParamGrid()
                case .xy: XYPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(6)
        .sheet(isPresented: $showBrowser) { BrowserView(inSheet: true) }
        .onAppear {
            if store.watchedTrack < 0, let first = store.tracks.first { store.watchTrack(first.i) }
        }
    }

    @ViewBuilder private var deviceTitle: some View {
        HStack {
            if let f = store.focused {
                Text(f.name).font(.headline).lineLimit(1)
                if f.className.contains("PluginDevice") && store.params.count <= 1 {
                    Text("No parameters exposed — click “Configure” on the plug-in in Live")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Pick a device").font(.headline).foregroundStyle(.secondary)
            }
        }
    }

    private var followToggle: some View {
        @Bindable var store = store
        return Toggle(isOn: $store.followLive) {
            Label("Follow Live", systemImage: "hand.point.up.left.fill")
        }
        .toggleStyle(.button)
        .font(.caption)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
    }
}

private struct TrackPicker: View {
    @Environment(LiveStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.tracks) { track in
                    let selected = track.i == store.watchedTrack
                    Text(track.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .foregroundStyle(selected ? .black : .white.opacity(0.85))
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? Color(live: track.color) : Theme.cell)
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color(live: track.color)).frame(height: 2)
                        }
                        .onTapGesture { store.watchTrack(track.i) }
                }
            }
        }
    }
}

private struct DeviceChain: View {
    @Environment(LiveStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if store.devices.isEmpty {
                    Text("No devices on this track")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(height: 44)
                }
                ForEach(store.devices) { device in
                    DeviceCard(device: device,
                               selected: store.focused?.t == store.watchedTrack && store.focused?.path == device.path)
                }
            }
        }
        .frame(height: 50)
    }
}

private struct DeviceCard: View {
    @Environment(LiveStore.self) private var store
    let device: DeviceInfo
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { store.toggleDevice(device) } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(device.isActive ? Theme.activator : .white.opacity(0.3))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                if !device.chain.isEmpty {
                    Text(device.chain).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Theme.accent.opacity(0.35) : Theme.cell)
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.accent : .clear, lineWidth: 1.5))
        .padding(.leading, CGFloat(device.depth) * 10)
        .overlay(alignment: .leading) {
            if device.depth > 0 {
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2, height: 30)
                    .padding(.leading, CGFloat(device.depth) * 10 - 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focusDevice(device) }
    }

    private var icon: String {
        if device.isRack { return "square.stack.3d.up" }
        if device.isPlugin { return "puzzlepiece.extension" }
        return "dial.medium"
    }
}

private struct ParamGrid: View {
    @Environment(LiveStore.self) private var store

    var body: some View {
        // Parameter 0 is always "Device On", handled by the power button.
        let params = Array(store.params.dropFirst())
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 12) {
                ForEach(params) { ParamControl(param: $0) }
            }
            .padding(6)
        }
    }
}

struct ParamControl: View {
    @Environment(LiveStore.self) private var store
    let param: ParamInfo

    var body: some View {
        VStack(spacing: 4) {
            if param.quantized && param.items.count == 2 {
                ToggleChip(label: param.display, isOn: param.value > param.min, onColor: Theme.accent) {
                    store.setParam(param.i, param.value > param.min ? param.min : param.max)
                }
                .frame(width: 70)
                .frame(height: 52)
            } else {
                Knob(value: param.normalized,
                     color: param.enabled ? Theme.accent : .gray,
                     steps: param.quantized ? Int(param.max - param.min) : nil,
                     onBegin: { store.beginTouch("p:\(param.i)") },
                     onChange: { store.setParam(param.i, param.value(fromNormalized: $0)) },
                     onEnd: { store.endTouch("p:\(param.i)") })
            }
            Text(param.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text(param.display)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 88)
        .opacity(param.enabled ? 1 : 0.5)
    }
}

private struct XYPanel: View {
    @Environment(LiveStore.self) private var store
    @State private var xIndex: Int?
    @State private var yIndex: Int?

    var body: some View {
        let params = store.params.filter { $0.i != 0 && !$0.quantized }
        let xp = params.first { $0.i == xIndex } ?? params.first
        let yp = params.first { $0.i == yIndex } ?? params.dropFirst().first ?? params.first

        if let xp, let yp {
            HStack(spacing: 12) {
                XYPad(x: xp.normalized, y: yp.normalized,
                      onBegin: {
                          store.beginTouch("p:\(xp.i)")
                          store.beginTouch("p:\(yp.i)")
                      },
                      onChange: { nx, ny in
                          store.setParam(xp.i, xp.value(fromNormalized: nx))
                          if yp.i != xp.i { store.setParam(yp.i, yp.value(fromNormalized: ny)) }
                      },
                      onEnd: {
                          store.endTouch("p:\(xp.i)")
                          store.endTouch("p:\(yp.i)")
                      })
                VStack(alignment: .leading, spacing: 14) {
                    axisPicker("X", selection: xp, params: params) { xIndex = $0 }
                    axisPicker("Y", selection: yp, params: params) { yIndex = $0 }
                    Spacer()
                }
                .frame(width: 180)
            }
            .onChange(of: store.focused) { xIndex = nil; yIndex = nil }
        } else {
            ContentUnavailableView("No continuous parameters", systemImage: "square.grid.3x3",
                                   description: Text("Pick a device with at least one knob."))
        }
    }

    private func axisPicker(_ axis: String, selection: ParamInfo, params: [ParamInfo],
                            onPick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(axis).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Menu {
                ForEach(params) { p in Button(p.name) { onPick(p.i) } }
            } label: {
                HStack {
                    Text(selection.name).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))
            }
            Text(selection.display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
