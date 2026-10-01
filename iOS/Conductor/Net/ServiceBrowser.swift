import Foundation
import Network
import Observation

/// Finds Macs running the Conductor remote script via Bonjour (_conductor._tcp).
@Observable
@MainActor
final class ServiceBrowser {
    struct Service: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var services: [Service] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_conductor._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Service? in
                if case let .service(name, _, _, _) = result.endpoint {
                    return Service(name: name, endpoint: result.endpoint)
                }
                return nil
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.services = found }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
