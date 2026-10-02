import SwiftUI
import UIKit

/// "Set up your Mac": sends the bundled Live remote script to the Mac and walks through installing it.
struct SetupView: View {
    @Environment(LiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showMIDI = false

    private static let remoteScriptsPath = "~/Music/Ableton/User Library/Remote Scripts"
    private var scriptZip: URL? { Bundle.main.url(forResource: "ConductorRemoteScript", withExtension: "zip") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.scriptOutdated {
                        Label("The script on your Mac is older than this app. Send the new one and replace the old Conductor folder.",
                              systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.callout.weight(.semibold))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.18)))
                    }
                    Text("Conductor talks to Live through a small remote script on your Mac. You only do this once (and again after app updates that need a newer script).")
                        .foregroundStyle(.secondary)

                    step(1, "Send the script to your Mac") {
                        Text("AirDrop works best: it lands in your Mac's Downloads folder as ConductorRemoteScript.zip.")
                        if let scriptZip {
                            ShareLink(item: scriptZip) {
                                Label("Send Script to Mac…", systemImage: "square.and.arrow.up")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                        }
                    }

                    step(2, "Install it") {
                        Text("On the Mac, unzip it and move the **Conductor** folder into:")
                        HStack {
                            Text(Self.remoteScriptsPath)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button {
                                UIPasteboard.general.string = Self.remoteScriptsPath
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                        Text("Tip: in Finder, press ⇧⌘G and paste the path. Create the **Remote Scripts** folder if it isn't there. If you're updating, replace the old Conductor folder.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    step(3, "Turn it on in Live") {
                        Text("Restart Live, then open **Settings › Link, Tempo & MIDI**. In an empty **Control Surface** row choose **Conductor**, with Input and Output set to **None**.")
                        Text("Live's status bar shows \u{201C}Conductor: listening on port 9001\u{201D}.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    step(4, "Connect") {
                        Text("Keep this device on the same Wi-Fi as your Mac. Your Mac appears on the connect screen; tap it. Next time Conductor connects by itself.")
                    }

                    step(5, "Optional: pads and keys") {
                        Text("Playing notes from Play uses network MIDI, which needs a one-time setting on the Mac.")
                        Button("Network MIDI setup…") { showMIDI = true }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Set Up Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .sheet(isPresented: $showMIDI) { MIDISetupSheet() }
        }
    }

    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}
