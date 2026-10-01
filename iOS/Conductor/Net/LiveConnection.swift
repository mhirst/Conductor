import Foundation
import Network
import os

/// Newline-delimited JSON over TCP to the Conductor remote script.
@MainActor
final class LiveConnection {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    var onStatus: ((Status) -> Void)?
    var onLine: ((Data) -> Void)?
    /// IPv4 address of the Mac once connected (used to join its network MIDI session).
    private(set) var remoteAddress: String?

    private var connection: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "conductor.net")

    func connect(to endpoint: NWEndpoint) {
        disconnect()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        buffer.removeAll()
        onStatus?(.connecting)

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.remoteAddress = Self.address(of: conn.currentPath?.remoteEndpoint)
                        ?? Self.address(of: conn.endpoint)
                    Logger(subsystem: "com.mhirst.conductor", category: "net")
                        .info("connected to Live, remote \(String(describing: conn.currentPath?.remoteEndpoint), privacy: .public) -> \(self.remoteAddress ?? "nil", privacy: .public)")
                    self.onStatus?(.connected)
                case .waiting(let error):
                    self.onStatus?(.failed(error.localizedDescription))
                case .failed(let error):
                    self.onStatus?(.failed(error.localizedDescription))
                    self.connection = nil
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    /// Plain address string for an endpoint (IPv4 preferred; hostnames and IPv6 accepted).
    private static func address(of endpoint: NWEndpoint?) -> String? {
        guard case let .hostPort(host, _)? = endpoint else { return nil }
        switch host {
        // Network.framework appends the interface ("192.168.1.5%en0"); CoreMIDI wants the bare address.
        case .ipv4(let a): return "\(a)".components(separatedBy: "%").first
        case .ipv6(let a): return "\(a)".components(separatedBy: "%").first
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }

    func send(_ message: [String: Any]) {
        guard let connection,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === conn else { return }
                if let data, !data.isEmpty { self.ingest(data) }
                if isComplete || error != nil {
                    self.connection = nil
                    conn.cancel()
                    self.onStatus?(.failed(error?.localizedDescription ?? "Live closed the connection"))
                    return
                }
                self.receive(on: conn)
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(Data(line)) }
        }
    }
}
