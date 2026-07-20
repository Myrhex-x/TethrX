import Foundation
import Network

/// Finds TethrX bridges advertising `_tethrx._tcp` on the local network, so the
/// pairing screens can offer "nearby computers" instead of a typed address. The
/// pairing token is still required — discovery only fills in where to connect.
@MainActor
final class BridgeDiscovery: ObservableObject {
    struct Found: Identifiable, Equatable {
        var name: String       // service name, e.g. "TethrX (mac-mini)"
        var address: String    // "192.168.1.10:4180"
        var id: String { address }
    }

    @Published var found: [Found] = []

    private var browser: NWBrowser?
    private var resolvers: [NWConnection] = []

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_tethrx._tcp", domain: nil), using: params)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        browser.stateUpdateHandler = { _ in }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for c in resolvers { c.cancel() }
        resolvers = []
        found = []
    }

    /// A Bonjour result is a service name, not an address — open a throwaway TCP
    /// connection to each and read the resolved remote endpoint off its path.
    private func resolve(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let conn = NWConnection(to: result.endpoint, using: .tcp)
            resolvers.append(conn)
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard case .ready = state, let conn else { return }
                let remote = conn.currentPath?.remoteEndpoint
                conn.cancel()
                Task { @MainActor in
                    guard let self else { return }
                    self.resolvers.removeAll { $0 === conn }
                    guard case let .hostPort(host, port) = remote else { return }
                    let address: String
                    switch host {
                    case .ipv4(let v4): address = "\(v4):\(port)"
                    default: return   // IPv6 link-local addresses don't round-trip through a URL cleanly
                    }
                    if !self.found.contains(where: { $0.address == address }) {
                        self.found.append(Found(name: name, address: address))
                    }
                }
            }
            conn.start(queue: .main)
        }
    }
}
