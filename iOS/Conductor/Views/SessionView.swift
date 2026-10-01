import SwiftUI

/// Clip-launch grid: tracks are columns, scenes are rows (like Live's Session View).
/// Track headers, the stop row and the scene column are frozen and follow the grid's scroll.
struct SessionView: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var gridPosition = ScrollPosition()
    @State private var headerPosition = ScrollPosition()
    @State private var stopPosition = ScrollPosition()
    @State private var scenePosition = ScrollPosition()
    @State private var gridViewport: CGSize = .zero

    private var cellW: CGFloat { sizeClass == .regular ? 112 : 92 }
    private var cellH: CGFloat { sizeClass == .regular ? 48 : 40 }
    private let gap: CGFloat = 2
    private var sceneW: CGFloat { sizeClass == .regular ? 120 : 96 }
    private let headerH: CGFloat = 34
    private let stopH: CGFloat = 34

    var body: some View {
        let tracks = visibleTracks
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: gap) {
                        ForEach(tracks) { track in
                            TrackHeader(track: track)
                                .frame(width: cellW, height: headerH)
                        }
                    }
                }
                .scrollPosition($headerPosition)
                .scrollDisabled(true)
                Text("Scenes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: sceneW, height: headerH)
            }
            .frame(height: headerH)

            HStack(spacing: gap) {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: gap) {
                        ForEach(store.scenes.indices, id: \.self) { s in
                            HStack(spacing: gap) {
                                ForEach(tracks) { track in
                                    ClipCell(
                                        slot: slot(track.i, s),
                                        armed: track.arm,
                                        progress: store.progress[SlotKey(t: track.i, s: s)]
                                    )
                                    .frame(width: cellW, height: cellH)
                                    .onTapGesture { store.fireClip(t: track.i, s: s) }
                                    .contextMenu {
                                        Button("Stop Clip", systemImage: "stop.fill") { store.stopClip(t: track.i, s: s) }
                                        Button("Stop Track", systemImage: "stop") { store.stopTrack(track.i) }
                                    }
                                }
                            }
                        }
                    }
                    // 2D scroll views center small content; pin it to the top-leading corner.
                    .frame(minWidth: gridViewport.width, minHeight: gridViewport.height, alignment: .topLeading)
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { gridViewport = $0 }
                .scrollIndicators(.hidden)
                .scrollPosition($gridPosition)
                .onScrollGeometryChange(for: CGPoint.self) { geo in
                    CGPoint(x: geo.contentOffset.x + geo.contentInsets.leading,
                            y: geo.contentOffset.y + geo.contentInsets.top)
                } action: { _, p in
                    headerPosition.scrollTo(x: p.x)
                    stopPosition.scrollTo(x: p.x)
                    scenePosition.scrollTo(y: p.y)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: gap) {
                        ForEach(store.scenes.indices, id: \.self) { s in
                            SceneButton(scene: store.scenes[s], index: s)
                                .frame(width: sceneW, height: cellH)
                                .onTapGesture { store.fireScene(s) }
                        }
                    }
                }
                .scrollPosition($scenePosition)
                .scrollDisabled(true)
                .frame(width: sceneW)
            }

            HStack(spacing: gap) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: gap) {
                        ForEach(tracks) { track in
                            StopButton(track: track)
                                .frame(width: cellW, height: stopH)
                                .onTapGesture { store.stopTrack(track.i) }
                        }
                    }
                }
                .scrollPosition($stopPosition)
                .scrollDisabled(true)
                Button { store.stopAll() } label: {
                    Label("Stop All", systemImage: "stop.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: sceneW, height: stopH)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.cell))
                }
                .buttonStyle(.plain)
            }
            .frame(height: stopH)
        }
        .padding(6)
    }

    /// Regular tracks, hiding the children of folded groups.
    private var visibleTracks: [TrackInfo] {
        let all = store.tracks
        return store.regularTracks.filter { track in
            var g = track.groupIndex
            while g >= 0, all.indices.contains(g) {
                if all[g].isFolded { return false }
                g = all[g].groupIndex
            }
            return true
        }
    }

    private func slot(_ t: Int, _ s: Int) -> SlotInfo {
        guard store.slots.indices.contains(t), store.slots[t].indices.contains(s) else { return .empty }
        return store.slots[t][s]
    }
}

struct TrackHeader: View {
    @Environment(LiveStore.self) private var store
    let track: TrackInfo

    var body: some View {
        HStack(spacing: 4) {
            if track.isGroup {
                Image(systemName: track.isFolded ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            Text(track.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.black.opacity(0.85))
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(live: track.color)))
        .overlay(alignment: .leading) {
            if track.groupIndex >= 0 {
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 3)
            }
        }
        .onTapGesture { if track.isGroup { store.toggleFold(track.i) } }
        .contextMenu {
            Button("Select in Live", systemImage: "cursorarrow.rays") { store.selectTrack(track.i) }
            Button("Stop Track", systemImage: "stop.fill") { store.stopTrack(track.i) }
            if track.canArm {
                Button(track.arm ? "Disarm" : "Arm", systemImage: "record.circle") { store.toggleArm(track.i) }
            }
        }
    }
}

struct ClipCell: View {
    let slot: SlotInfo
    let armed: Bool
    let progress: Double?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 5).fill(background)
            HStack(spacing: 5) {
                icon
                if slot.hasClip {
                    Text(slot.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(textColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(maxHeight: .infinity)

            if slot.state == .playing, let progress {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: geo.size.width * progress, height: 3)
                        .animation(.linear(duration: 0.1), value: progress)
                }
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.horizontal, 3)
                .padding(.bottom, 3)
            }
        }
        .overlay {
            if slot.state == .playing {
                RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.9), lineWidth: 2)
            }
        }
        .modifier(Blink(active: slot.state == .triggered))
        .contentShape(Rectangle())
    }

    private var clipColor: Color { Color(live: slot.color) }

    private var background: Color {
        if slot.isGroupSlot { return Theme.cell.opacity(slot.state == .playing ? 1 : 0.7) }
        if !slot.hasClip { return Theme.cell.opacity(0.55) }
        switch slot.state {
        case .playing, .recording, .triggered: return clipColor
        default: return clipColor.opacity(0.55)
        }
    }

    private var textColor: Color {
        slot.state == .stopped ? .white.opacity(0.9) : .black.opacity(0.85)
    }

    @ViewBuilder private var icon: some View {
        switch slot.state {
        case .playing:
            Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(slot.hasClip ? .black : Theme.play)
        case .recording:
            Image(systemName: "record.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.record)
        case .triggered:
            Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
        case .stopped:
            Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        case .empty:
            if armed {
                Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(Theme.record.opacity(0.8))
            } else if slot.hasStop {
                Image(systemName: "square").font(.system(size: 7)).foregroundStyle(.white.opacity(0.25))
            }
        }
    }
}

struct SceneButton: View {
    let scene: SceneInfo
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill").font(.system(size: 10))
            Text(scene.name.isEmpty ? "\(index + 1)" : scene.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(scene.color == 0 ? Theme.panel : Color(live: scene.color).opacity(0.6))
        )
        .modifier(Blink(active: scene.triggered))
        .contentShape(Rectangle())
    }
}

struct StopButton: View {
    let track: TrackInfo

    var body: some View {
        let playing = track.playingSlot >= 0
        Image(systemName: "square.fill")
            .font(.system(size: 11))
            .foregroundStyle(playing ? Color.white : Color.white.opacity(0.3))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.cell))
            .modifier(Blink(active: track.firedSlot == -2))
            .contentShape(Rectangle())
    }
}

/// Flashes a view while a clip/scene is waiting for launch quantization.
struct Blink: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([1.0, 0.35]) { view, phase in
                view.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.18) }
        } else {
            content
        }
    }
}
