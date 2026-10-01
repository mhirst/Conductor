import SwiftUI

enum Screen: String, CaseIterable {
    case session = "Session", mixer = "Mixer", devices = "Devices", play = "Play", sequencer = "Steps", browse = "Browse"

    /// iPhone tabs: five fit without iOS folding the rest into "More"; Browse opens as a sheet instead.
    static var phoneTabs: [Screen] { allCases.filter { $0 != .browse } }

    var icon: String {
        switch self {
        case .session: "square.grid.3x3.fill"
        case .mixer: "slider.vertical.3"
        case .devices: "dial.medium.fill"
        case .play: "circle.grid.3x3.fill"
        case .sequencer: "square.grid.4x3.fill"
        case .browse: "books.vertical.fill"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .session: SessionView()
        case .mixer: MixerView()
        case .devices: DevicesView()
        case .play: PlayView()
        case .sequencer: SequencerView()
        case .browse: BrowserView()
        }
    }
}

struct RootView: View {
    @Environment(LiveStore.self) private var store
    @AppStorage("screen") private var screen: Screen = .session

    var body: some View {
        Group {
            if store.hasState, Layout.isPhone {
                PhoneRootView(screen: $screen)
            } else if store.hasState {
                VStack(spacing: 0) {
                    TransportBar(screen: $screen)
                    screen.view
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .top) {
                    if case .failed = store.status {
                        Label("Reconnecting to Live…", systemImage: "wifi.exclamationmark")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.record.opacity(0.9)))
                            .padding(.top, 52)
                    }
                }
            } else {
                ConnectView()
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

/// iPhone: native tab bar for the five screens, slim transport bar on top of each.
struct PhoneRootView: View {
    @Environment(LiveStore.self) private var store
    @Binding var screen: Screen

    var body: some View {
        TabView(selection: $screen) {
            ForEach(Screen.phoneTabs, id: \.self) { s in
                Tab(s.rawValue, systemImage: s.icon, value: s) {
                    VStack(spacing: 0) {
                        TransportBar(screen: $screen, showsPicker: false)
                        s.view.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Theme.background.ignoresSafeArea())
                }
            }
        }
        .overlay(alignment: .top) {
            if case .failed = store.status {
                Label("Reconnecting to Live…", systemImage: "wifi.exclamationmark")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.record.opacity(0.9)))
                    .padding(.top, 50)
            }
        }
        .onAppear { if screen == .browse { screen = .play } }
    }
}

struct TransportBar: View {
    @Environment(LiveStore.self) private var store
    @Binding var screen: Screen
    var showsPicker = true
    @State private var tempoStart: Double?

    var body: some View {
        HStack(spacing: Layout.isPhone ? 6 : 8) {
            if showsPicker {
                Picker("Screen", selection: $screen) {
                    ForEach(Screen.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)

                Spacer(minLength: 4)
            }

            transportButton("play.fill", on: store.song.isPlaying, color: Theme.play) { store.play() }
            transportButton("stop.fill", on: false, color: .white) { store.stop() }
            transportButton("record.circle", on: store.song.sessionRecord, color: Theme.record) { store.toggleSessionRecord() }

            // Tempo: drag vertically to change, tap to tap-tempo.
            VStack(spacing: 0) {
                Text(String(format: "%.2f", store.song.tempo))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                Text("BPM").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(width: Layout.isPhone ? 64 : 70, height: 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        if tempoStart == nil { tempoStart = store.song.tempo; store.beginTouch("tempo") }
                        let bpm = (tempoStart ?? 120) - Double(g.translation.height) / 4
                        store.setTempo((bpm * 10).rounded() / 10)
                    }
                    .onEnded { _ in tempoStart = nil; store.endTouch("tempo") }
            )
            .onTapGesture { store.tapTempo() }

            Text(beatString)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: Layout.isPhone ? 50 : 60, height: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))

            transportButton("metronome", on: store.song.metronome, color: Theme.accent) { store.toggleMetronome() }

            if !showsPicker { Spacer(minLength: 0) }

            Menu {
                Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }.disabled(!store.song.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }.disabled(!store.song.canRedo)
                Divider()
                Button("Disconnect from \(store.hostName)", systemImage: "xmark.circle", role: .destructive) {
                    store.disconnect()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.panel)
    }

    private var beatString: String {
        let perBar = Double(max(1, store.song.sigNum)) * 4 / Double(max(1, store.song.sigDen))
        let bar = Int(store.beat / perBar) + 1
        let beat = Int(store.beat.truncatingRemainder(dividingBy: perBar) * Double(store.song.sigDen) / 4) + 1
        return "\(bar).\(beat)"
    }

    private func transportButton(_ icon: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? Color.black : color.opacity(0.9))
                .frame(width: Layout.isPhone ? 40 : 44, height: 36)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? color : Theme.cell))
        }
        .buttonStyle(.plain)
    }
}

struct ConnectView: View {
    @Environment(LiveStore.self) private var store
    @State private var browser = ServiceBrowser()
    @AppStorage("lastHost") private var host = ""
    @AppStorage("lastService") private var lastService = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Conductor").font(.largeTitle.weight(.bold))
                    Text("Control Ableton Live's clips, mixer and devices.")
                        .foregroundStyle(.secondary)
                }

                statusView

                VStack(alignment: .leading, spacing: 8) {
                    Text("Found on your network").font(.headline)
                    if browser.services.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Looking for Live…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.services) { service in
                        Button {
                            lastService = service.name
                            store.connect(to: service.endpoint)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(service.name).fontWeight(.semibold)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Or enter your Mac's address").font(.headline)
                    HStack {
                        TextField("192.168.1.20", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { store.connect(host: host) }
                        Button("Connect") { store.connect(host: host) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(host.isEmpty)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Setup").font(.headline)
                    Text("1. Run `RemoteScript/install.sh` on your Mac.")
                    Text("2. In Live: Settings › Link, Tempo & MIDI › Control Surface → **Conductor** (Input/Output: None).")
                    Text("3. Keep this device on the same Wi-Fi network as your Mac.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .onChange(of: browser.services) { _, services in
            // Auto-connect to the Mac we used last time.
            guard store.status == .idle, let s = services.first(where: { $0.name == lastService }) else { return }
            store.connect(to: s.endpoint)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch store.status {
        case .connecting:
            Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(Theme.accent)
        case .connected:
            Label("Connected, loading session…", systemImage: "checkmark.circle").foregroundStyle(Theme.play)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.record)
        case .idle:
            EmptyView()
        }
    }
}
