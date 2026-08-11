import Foundation
import CryptoKit

/// Certificate pinning for the bridge's self-signed HTTPS.
///
/// There is no CA and no hostname to trust — the app learns the certificate's
/// SHA-256 fingerprint out-of-band (the pairing QR, or a bridge it already
/// trusts) and accepts exactly that certificate, nothing else. Stronger than web
/// PKI for a two-party setup, and immune to a hostile network swapping the cert.
final class PinningDelegate: NSObject, URLSessionDelegate {
    private let pin: String   // lowercase hex SHA-256 of the DER certificate

    init(pin: String) { self.pin = pin.lowercased() }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        let der = SecCertificateCopyData(leaf) as Data
        let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if hash == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Cached URLSessions per fingerprint. `BridgeClient` is a lightweight struct built on
/// every access, and URLSessions must not be created per call.
///
/// There are TWO per pin, and the distinction matters more than it looks.
/// `timeoutIntervalForResource` is a ceiling on a task's ENTIRE lifetime, and unlike
/// `timeoutIntervalForRequest` a single request cannot raise it. A 30 second ceiling on
/// the one shared session therefore killed the SSE chat stream every 30 seconds forever
/// (it asks for 3600), and made compact, branch, plugin actions and grok update, which
/// ask for 200 to 320 seconds, impossible to complete. Since the bridge mints a
/// certificate whenever openssl is present and the app upgrades to it on first connect,
/// that was every user, all the time.
enum PinnedSessions {
    private static let lock = NSLock()

    /// For everything real: streaming, and any request that may legitimately take minutes.
    static func session(for pin: String) -> URLSession {
        cached(pin, in: \.longRunning, resourceTimeout: nil)
    }

    /// For reachability probes only. A pinned port that accepts the connection and then
    /// stalls (a dead TLS listener, something else squatting the port) would otherwise
    /// hold on far past the request timeout, which reads as a frozen Reconnect button.
    static func probeSession(for pin: String) -> URLSession {
        cached(pin, in: \.probes, resourceTimeout: 30)
    }

    private static func cached(_ pin: String,
                               in keyPath: ReferenceWritableKeyPath<Store, [String: URLSession]>,
                               resourceTimeout: TimeInterval?) -> URLSession {
        let key = pin.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let existing = store[keyPath: keyPath][key] { return existing }
        let config = URLSessionConfiguration.default
        if let resourceTimeout { config.timeoutIntervalForResource = resourceTimeout }
        let session = URLSession(configuration: config, delegate: PinningDelegate(pin: key), delegateQueue: nil)
        store[keyPath: keyPath][key] = session
        return session
    }

    /// Boxed so the two caches can be addressed by key path under one lock.
    final class Store {
        var longRunning: [String: URLSession] = [:]
        var probes: [String: URLSession] = [:]
    }
    private static let store = Store()
}
