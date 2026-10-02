import SwiftUI

struct MixerView: View {
    @Environment(LiveStore.self) private var store

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(store.regularTracks) { ChannelStrip(track: $0) }
                if !store.returnTracks.isEmpty {
                    Divider().overlay(Color.white.opacity(0.2)).padding(.horizontal, 4)
                    ForEach(store.returnTracks) { ChannelStrip(track: $0) }
                }
                if let master = store.masterTrack {
                    Divider().overlay(Color.white.opacity(0.2)).padding(.horizontal, 4)
                    ChannelStrip(track: master)
                }
            }
            .padding(6)
        }
        .scrollIndicators(.hidden)
    }
}

struct ChannelStrip: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.verticalSizeClass) private var vSize
    @AppStorage("screen") private var screen: Screen = .session
    let track: TrackInfo

    /// iPhone in landscape: no room for the rack and sends, so the fader gets the height.
    private var phoneLandscape: Bool { Layout.isPhone && vSize == .compact }

    var body: some View {
        let color = Color(live: track.color)
        VStack(spacing: 6) {
            Text(track.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(.black.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: 4).fill(color))
                .onTapGesture { store.selectTrack(track.i) }

            if !phoneLandscape { effectsRack }

            if !track.sends.isEmpty, !phoneLandscape {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 2)], spacing: 4) {
                    ForEach(Array(track.sends.enumerated()), id: \.offset) { idx, value in
                        VStack(spacing: 1) {
                            Knob(value: value, color: Theme.solo, size: 28, defaultValue: 0,
                                 onBegin: { store.beginTouch("send:\(track.i):\(idx)") },
                                 onChange: { store.setSend(track.i, idx, $0) },
                                 onEnd: { store.endTouch("send:\(track.i):\(idx)") })
                            Text(sendLetter(idx)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !phoneLandscape {
                Color.clear.frame(height: 41)   // master has no sends: keep its fader level with the rest
            }

            VStack(spacing: 1) {
                Knob(value: (track.pan + 1) / 2, color: color, bipolar: true, size: phoneLandscape ? 30 : 38, defaultValue: 0.5,
                     onBegin: { store.beginTouch("pan:\(track.i)") },
                     onChange: { store.setPan(track.i, $0 * 2 - 1) },
                     onEnd: { store.endTouch("pan:\(track.i)") })
                Text(track.panStr).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                VerticalFader(value: track.volume, color: color,
                              onBegin: { store.beginTouch("vol:\(track.i)") },
                              onChange: { store.setVolume(track.i, $0) },
                              onEnd: { store.endTouch("vol:\(track.i)") })
                LevelMeter(levels: store.meters.indices.contains(track.i) ? store.meters[track.i] : [0, 0])
                    .frame(width: 10)
            }
            .frame(maxHeight: .infinity)

            Text(track.volumeStr)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            buttons
        }
        .padding(5)
        .frame(width: Layout.isPhone ? 76 : 88)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
    }

    @ViewBuilder private var buttons: some View {
        let activator = ToggleChip(label: track.kind == .return ? sendLetter(track.i - store.regularTracks.count) : "\(track.i + 1)",
                                   isOn: !track.mute, onColor: Theme.activator) { store.toggleMute(track.i) }
        let solo = ToggleChip(label: "S", isOn: track.solo, onColor: Theme.solo) { store.toggleSolo(track.i) }
        let arm = ToggleChip(label: "", systemImage: "record.circle", isOn: track.arm, onColor: Theme.record) {
            store.toggleArm(track.i)
        }
        // Missing buttons keep their space so every fader is the same height and levels line up.
        let blank = Color.clear.frame(height: 30)
        if phoneLandscape {
            // Side by side to save height.
            if track.kind != .master { HStack(spacing: 3) { activator; solo } } else { blank }
            if track.canArm { arm } else { blank }
        } else {
            if track.kind != .master { activator; solo } else { blank; blank }
            if track.canArm { arm } else { blank }
        }
    }

    /// The track's devices, each with an on/off toggle. Tap a name to edit it in Devices.
    private var effectsRack: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                if track.devices.isEmpty {
                    Text("No devices").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
                ForEach(Array(track.devices.enumerated()), id: \.offset) { idx, device in
                    HStack(spacing: 3) {
                        Button { store.toggleTrackDevice(t: track.i, index: idx) } label: {
                            Image(systemName: "power")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(device.isActive ? Theme.activator : .white.opacity(0.3))
                                .frame(width: 18, height: 20)
                        }
                        .buttonStyle(.plain)
                        Text(device.name)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(device.isActive ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.openDevice(t: track.i, index: idx)
                                screen = .devices
                            }
                    }
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.cell))
                }
            }
        }
        .frame(height: Layout.isPhone ? 66 : 88)
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.25)))
    }

    private func sendLetter(_ idx: Int) -> String {
        guard idx >= 0, idx < 26 else { return "\(idx + 1)" }
        return String(UnicodeScalar(UInt8(65 + idx)))
    }
}

/// Stereo output meter (Live's meter values are already 0...1, display-scaled).
struct LevelMeter: View {
    let levels: [Double]

    var body: some View {
        HStack(spacing: 1) {
            bar(levels.first ?? 0)
            bar(levels.count > 1 ? levels[1] : levels.first ?? 0)
        }
    }

    private func bar(_ level: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.5))
                Rectangle()
                    .fill(LinearGradient(colors: [Theme.play, Theme.play, Theme.activator, Theme.record],
                                         startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: geo.size.height * min(1, max(0, level)))
                    }
            }
            .animation(.linear(duration: 0.1), value: level)
        }
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }
}
