import SwiftUI

/// Push-style browser over Live's library: pick a category, drill into folders, tap to load.
/// Presets load on tap; devices (Drift, Drum Rack…) open to their presets and load via their Load button.
struct BrowserView: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var inSheet = false

    @AppStorage("browserCat") private var cat = "drums"
    @State private var path: [Int] = []
    @State private var titles: [String] = []
    @State private var query = ""
    @State private var target: Int? = nil          // nil = new MIDI track
    @State private var targetChosen = false
    @State private var previewing: [Int]?
    @State private var toast: String?

    private var listing: BrowseMsg? {
        guard let l = store.browserListing, l.cat == cat, l.path == path else { return nil }
        return l
    }
    private var categoryName: String { store.browserCategories.first { $0.key == cat }?.name ?? "" }

    var body: some View {
        VStack(spacing: 8) {
            header
            categoryChips
            breadcrumb
            list
        }
        .padding(8)
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(Theme.panel))
                    .overlay(Capsule().stroke(Theme.play.opacity(0.6)))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            if store.browserCategories.isEmpty { store.browseCategories() }
            if !targetChosen { target = store.instrumentTrack >= 0 ? store.instrumentTrack : nil }
            if titles.isEmpty { open(category: cat) }
        }
        .onDisappear { stopPreview() }
        // After loading onto a new track, keep browsing on that track (tapping swaps its sound, like Push).
        .onChange(of: store.browserNewTrack) { _, t in
            guard let t else { return }
            target = t
            targetChosen = true
            store.browserNewTrack = nil
        }
        .onChange(of: store.browserCategories) { _, cats in
            if let name = cats.first(where: { $0.key == cat })?.name, !titles.isEmpty { titles[0] = name }
        }
        .onChange(of: store.lastLoaded) { _, msg in
            guard let msg else { return }
            withAnimation { toast = msg }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { if toast == msg { toast = nil } }
            }
            store.lastLoaded = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Browse").font(.headline)
            Spacer()
            Text("Loads onto").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button { target = nil; targetChosen = true } label: {
                    Label("New MIDI track", systemImage: target == nil ? "checkmark" : "plus")
                }
                Divider()
                ForEach(store.regularTracks) { t in
                    Button { target = t.i; targetChosen = true } label: {
                        Label(t.name, systemImage: target == t.i ? "checkmark" : (t.midi ? "pianokeys" : "waveform"))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(targetColor).frame(width: 8, height: 8)
                    Text(targetName).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))
            }
            if inSheet {
                Button("Done") { dismiss() }.font(.callout.weight(.semibold))
            }
        }
    }

    private var targetName: String {
        guard let target, store.tracks.indices.contains(target) else { return "New MIDI track" }
        return store.tracks[target].name
    }
    private var targetColor: Color {
        guard let target, store.tracks.indices.contains(target) else { return .white.opacity(0.5) }
        return Color(live: store.tracks[target].color)
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.browserCategories) { c in
                    let selected = c.key == cat
                    Text(c.name)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .foregroundStyle(selected ? .black : .white.opacity(0.85))
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent : Theme.cell))
                        .onTapGesture { open(category: c.key) }
                }
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button {
                guard !path.isEmpty else { return }
                path.removeLast()
                titles.removeLast()
                query = ""
                store.browse(cat: cat, path: path)
            } label: {
                Image(systemName: "chevron.left").frame(width: 30, height: 30)
            }
            .disabled(path.isEmpty)
            Text(titles.joined(separator: " › "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Filter", text: $query)
                    .font(.callout)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 8)
            .frame(width: Layout.isPhone ? 130 : 200, height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cell))
        }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        if let listing {
            let rows = listing.items.enumerated().filter { query.isEmpty || $0.element.name.localizedCaseInsensitiveContains(query) }
            if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Empty folder" : "No matches", systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows, id: \.offset) { idx, item in
                            row(idx, item)
                        }
                        if listing.truncated {
                            Text("Showing the first \(listing.items.count) items — use the filter to narrow down.")
                                .font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ idx: Int, _ item: BrowserItem) -> some View {
        let itemPath = path + [idx]
        return HStack(spacing: 10) {
            Image(systemName: icon(for: item))
                .font(.system(size: 14))
                .foregroundStyle(item.isOpenable ? Theme.accent : .secondary)
                .frame(width: 22)
            Text(displayName(item.name))
                .font(.system(size: 14, weight: item.isOpenable ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
            if store.browserCanPreview, item.isLoadable, !item.isOpenable {
                Button { togglePreview(itemPath) } label: {
                    Image(systemName: previewing == itemPath ? "speaker.wave.2.fill" : "speaker.wave.1")
                        .foregroundStyle(previewing == itemPath ? Theme.play : .secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            if item.isLoadable && item.isOpenable {
                // A device that also has presets: open it by tapping the row, load the bare device here.
                Button("Load") { load(itemPath) }
                    .font(.caption.weight(.bold))
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
            if item.isOpenable {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
        .contentShape(Rectangle())
        .onTapGesture {
            if item.isOpenable {
                stopPreview()
                path = itemPath
                titles.append(displayName(item.name))
                query = ""
                store.browse(cat: cat, path: path)
            } else if item.isLoadable {
                load(itemPath)
            }
        }
    }

    // MARK: Actions

    private func open(category key: String) {
        stopPreview()
        cat = key
        path = []
        query = ""
        titles = [store.browserCategories.first { $0.key == key }?.name ?? key]
        store.browse(cat: key, path: [])
    }

    private func load(_ itemPath: [Int]) {
        stopPreview()
        store.browserLoad(cat: cat, path: itemPath, toTrack: target)
    }

    private func togglePreview(_ itemPath: [Int]) {
        if previewing == itemPath {
            stopPreview()
        } else {
            previewing = itemPath
            store.browserPreview(cat: cat, path: itemPath)
        }
    }

    private func stopPreview() {
        guard previewing != nil else { return }
        previewing = nil
        store.browserStopPreview()
    }

    private func displayName(_ name: String) -> String {
        for ext in [".adg", ".adv", ".amxd", ".alc", ".als", ".aupreset", ".vstpreset", ".fxp"] where name.lowercased().hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    private func icon(for item: BrowserItem) -> String {
        let n = item.name.lowercased()
        if item.isFolder { return "folder.fill" }
        if item.isDevice { return cat == "plugins" ? "puzzlepiece.extension.fill" : "dial.medium.fill" }
        if n.hasSuffix(".adg") || n.hasSuffix(".adv") || n.hasSuffix("preset") || n.hasSuffix(".fxp") { return "slider.horizontal.3" }
        if n.hasSuffix(".wav") || n.hasSuffix(".aif") || n.hasSuffix(".aiff") || n.hasSuffix(".flac") || n.hasSuffix(".mp3") { return "waveform" }
        if n.hasSuffix(".alc") { return "rectangle.fill" }
        if n.hasSuffix(".amxd") { return "m.square.fill" }
        if n.hasSuffix(".als") { return "doc.fill" }
        return item.isLoadable ? "music.note" : "folder"
    }
}
