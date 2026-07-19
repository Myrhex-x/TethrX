import SwiftUI
import AVFoundation
import UIKit

/// Camera QR scanner sheet with a hint overlay + permission handling. Calls
/// `onPair` with the raw scanned string (a `tethrx://pair?…` URL from the bridge).
struct ScanSheet: View {
    let onPair: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch status {
            case .authorized:
                QRScannerView { code in onPair(code) }.ignoresSafeArea()
                RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 240, height: 240)
            case .denied, .restricted:
                denied
            default:
                Text("Requesting camera access…").font(Grok.mono(13)).foregroundStyle(.white.opacity(0.7))
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white).padding(12).background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                }
                Spacer()
                if status == .authorized {
                    Text("open  localhost:4180/pair  on your computer\nand point the camera at a code")
                        .font(Grok.mono(13)).foregroundStyle(.white).multilineTextAlignment(.center).lineSpacing(3)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 30)
                }
            }
            .padding(20)
        }
        .task {
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private var denied: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.7))
            Text("Camera access is off").font(Grok.sans(17, .semibold)).foregroundStyle(.white)
            Text("Turn on the camera for TethrX in Settings to scan the pairing code — or just type the address and token by hand.")
                .font(Grok.mono(12)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).lineSpacing(2)
            Button("Open Settings") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            .buttonStyle(PillButton(kind: .prominent)).padding(.top, 4)
        }
        .padding(34)
    }
}

/// AVFoundation QR scanner wrapped as a view controller.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(); vc.onScan = onScan; return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var handled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let pv = AVCaptureVideoPreviewLayer(session: session)
            pv.videoGravity = .resizeAspectFill
            view.layer.addSublayer(pv)
            preview = pv
        }

        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
            }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !handled,
                  let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let str = obj.stringValue else { return }
            handled = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            session.stopRunning()
            onScan?(str)
        }
    }
}
