import CoreMIDI
import Foundation
import Network
import Observation
import os

private let log = Logger(subsystem: "com.mhirst.conductor", category: "midi")

/// Sends notes straight to the Mac over CoreMIDI (network session / USB), bypassing the
/// remote script so playing isn't limited by Live's ~10 Hz script tick.
@Observable
@MainActor
final class MIDIOut {
    private(set) var destinations: [String] = []
    private(set) var networkConnections: [String] = []
    var channel: UInt8 = 0

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var port = MIDIPortRef()

    init() {
        let session = MIDINetworkSession.default()
        session.isEnabled = true
        session.connectionPolicy = .anyone

        MIDIClientCreateWithBlock("Conductor" as CFString, &client) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        MIDIOutputPortCreate(client, "Conductor Out" as CFString, &port)
        refresh()
    }

    func refresh() {
        destinations = (0..<MIDIGetNumberOfDestinations()).map { Self.name(of: MIDIGetDestination($0)) }
        networkConnections = MIDINetworkSession.default().connections().map { "\($0.host.name) — \($0.host.address):\($0.host.port)" }
    }

    @ObservationIgnored private var rtpBrowser: NWBrowser?
    @ObservationIgnored private var liveAddress: String?
    @ObservationIgnored private var liveName = "Live"
    @ObservationIgnored private var probes: [String: NWConnection] = [:]

    /// Joins the RTP-MIDI session on the Mac running Live. The session's port is found over
    /// Bonjour (_apple-midi._udp) rather than assumed, and our own session is skipped.
    func joinMacSession(address: String, name: String) {
        liveAddress = address
        liveName = name
        let session = MIDINetworkSession.default()
        log.info("join mac session \(address, privacy: .public), own port \(session.networkPort), existing \(session.connections().map { "\($0.host.address):\($0.host.port)" }, privacy: .public)")
        // Drop stale self-connections (possible in the Simulator, which shares the Mac's IP).
        for c in session.connections() where c.host.address == address && c.host.port == Int(session.networkPort) {
            session.removeConnection(c)
        }
        // Fallback when the Mac's session isn't advertised on Bonjour (its Network Name is blank):
        // use the port from the MIDI sheet (default 5004).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, let address = self.liveAddress else { return }
            let session = MIDINetworkSession.default()
            guard !session.connections().contains(where: { $0.host.address == address }) else { return }
            let port = UserDefaults.standard.object(forKey: "midiPort") as? Int ?? 5004
            if port != Int(session.networkPort) { self.connectNetwork(toAddress: address, port: port) }
        }
        guard rtpBrowser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_apple-midi._udp", domain: nil), using: .udp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in endpoints.forEach { self?.probe($0) } }
        }
        browser.start(queue: .main)
        rtpBrowser = browser
    }

    /// Resolves a Bonjour RTP-MIDI service to ip:port and connects if it's on Live's Mac.
    private func probe(_ endpoint: NWEndpoint) {
        let key = "\(endpoint)"
        guard probes[key] == nil else { return }
        let params = NWParameters.udp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        probes[key] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            let remote = conn.currentPath?.remoteEndpoint
            conn.cancel()
            Task { @MainActor in
                guard let self, case let .hostPort(host, port)? = remote, case let .ipv4(ipv4) = host else { return }
                let addr = "\(ipv4)".components(separatedBy: "%").first ?? "\(ipv4)"
                let session = MIDINetworkSession.default()
                let p = Int(port.rawValue)
                log.info("found RTP session at \(addr, privacy: .public):\(p)")
                guard addr == self.liveAddress, p != Int(session.networkPort) else { return }
                self.connectNetwork(toAddress: addr, port: p)
            }
        }
        conn.start(queue: .main)
    }

    /// Replace the connection to Live's Mac with one on a specific port (from the MIDI sheet).
    func reconnect(port: Int) {
        guard let address = liveAddress else { return }
        let session = MIDINetworkSession.default()
        for c in session.connections() where c.host.address == address { session.removeConnection(c) }
        connectNetwork(toAddress: address, port: port)
    }

    private func connectNetwork(toAddress address: String, port: Int) {
        let session = MIDINetworkSession.default()
        if session.connections().contains(where: { $0.host.address == address && $0.host.port == port }) { return }
        log.info("adding RTP connection \(address, privacy: .public):\(port)")
        session.addConnection(MIDINetworkConnection(host: MIDINetworkHost(name: liveName, address: address, port: port)))
        refresh()
    }

    // MARK: Messages

    func noteOn(_ note: Int, velocity: Int) {
        guard (0...127).contains(note) else { return }
        send(0x90 | channel, UInt8(note), UInt8(max(1, min(127, velocity))))
    }

    func noteOff(_ note: Int) {
        guard (0...127).contains(note) else { return }
        send(0x80 | channel, UInt8(note), 0)
    }

    /// -1...1, 0 = centre.
    func pitchBend(_ value: Double) {
        let v = UInt16(max(0, min(16383, (value + 1) / 2 * 16383)))
        send(0xE0 | channel, UInt8(v & 0x7F), UInt8(v >> 7))
    }

    func controlChange(_ cc: UInt8, _ value: Double) {
        send(0xB0 | channel, cc, UInt8(max(0, min(127, value * 127))))
    }

    func allNotesOff() {
        send(0xB0 | channel, 123, 0)
    }

    private func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        var word: UInt32 = (0x2 << 28) | (UInt32(status) << 16) | (UInt32(d1) << 8) | UInt32(d2)
        var list = MIDIEventList()
        withUnsafeMutablePointer(to: &list) { listPtr in
            let packet = MIDIEventListInit(listPtr, ._1_0)
            _ = MIDIEventListAdd(listPtr, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
            var sent = Set<MIDIEndpointRef>()
            for i in 0..<MIDIGetNumberOfDestinations() {
                let dest = MIDIGetDestination(i)
                if sent.insert(dest).inserted { MIDISendEventList(port, dest, listPtr) }
            }
            let net = MIDINetworkSession.default().destinationEndpoint()
            if net != 0, !sent.contains(net) { MIDISendEventList(port, net, listPtr) }
        }
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf)
        return (cf?.takeRetainedValue() as String?) ?? "MIDI"
    }
}
