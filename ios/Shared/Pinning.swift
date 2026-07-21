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

/// One URLSession per fingerprint, cached — `BridgeClient` is a lightweight
/// struct built on every access, and URLSessions must not be created per call.
enum PinnedSessions {
    private static let lock = NSLock()
    private static var cache: [String: URLSession] = [:]

    static func session(for pin: String) -> URLSession {
        let key = pin.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: PinningDelegate(pin: key), delegateQueue: nil)
        cache[key] = session
        return session
    }
}
