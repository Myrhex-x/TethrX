import Foundation

// Dev-only harness: exercises the app's REAL BridgeClient/Models against a live
// bridge, proving the native networking + SSE parser end-to-end without the UI.
//   swiftc -swift-version 5 -parse-as-library ../GrokRemote/Models.swift \
//          ../GrokRemote/BridgeClient.swift probe.swift -o probe
//   TOKEN=<pairing-token> ./probe
@main
struct Probe {
    static func main() async {
        let token = ProcessInfo.processInfo.environment["TOKEN"] ?? ""
        let client = BridgeClient(config: .init(baseURL: URL(string: "http://127.0.0.1:4180")!, token: token))
        do {
            let h = try await client.health()
            print("HEALTH ok=\(h.ok) grok=\(h.grok ?? "nil")")

            let cwd = NSHomeDirectory() + "/Developer/grok-remote/sandbox"
            let session = try await client.createSession(cwd: cwd)
            print("SESSION \(session.id)")

            let streamTask = Task {
                var answer = ""
                do {
                    for try await ev in client.events(sessionId: session.id) {
                        switch ev["kind"] as? String {
                        case "text": answer += ev["text"] as? String ?? ""
                        case "end": print("STREAM end:", ev["stopReason"] as? String ?? "")
                        case "turn_complete": print("STREAM answer:", answer.trimmingCharacters(in: .whitespacesAndNewlines)); return
                        case "error": print("STREAM error:", ev["message"] as? String ?? ""); return
                        default: break
                        }
                    }
                } catch { print("STREAM threw:", error) }
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            try await client.send(sessionId: session.id, text: "Reply with exactly: pong-from-swift. Do not use any tools.")
            _ = await streamTask.value
            print("DONE")
        } catch {
            print("ERROR", error)
        }
        exit(0)
    }
}
