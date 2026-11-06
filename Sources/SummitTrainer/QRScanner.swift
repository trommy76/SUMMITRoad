#if os(iOS)
import SwiftUI
import AVFoundation

/// Camera view that reports the first QR code it sees.
private struct QRCameraView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onUnavailable: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraController {
        let c = QRCameraController()
        c.onCode = onCode
        c.onUnavailable = onUnavailable
        return c
    }

    func updateUIViewController(_ controller: QRCameraController, context: Context) {}
}

private final class QRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onUnavailable: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private var configured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.configure() : self.onUnavailable?("Camera access is off. Turn it on for SummitRoad in the Settings app.") }
            }
        default:
            onUnavailable?("Camera access is off. Turn it on for SummitRoad in the Settings app.")
        }
    }

    private func configure() {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onUnavailable?("This device has no camera that can scan.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { onUnavailable?("The camera could not be set up."); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        configured = true
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
        if let conn = preview.connection, conn.isVideoOrientationSupported {
            switch view.window?.windowScene?.interfaceOrientation {
            case .landscapeLeft: conn.videoOrientation = .landscapeLeft
            case .landscapeRight: conn.videoOrientation = .landscapeRight
            case .portraitUpsideDown: conn.videoOrientation = .portraitUpsideDown
            default: conn.videoOrientation = .portrait
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        onCode?(text)
    }
}

/// Full-screen scanner for the server's "Connect an app" QR code.
struct QRScanSheet: View {
    var onLink: (ConnectLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var hint = "Point the camera at the QR code on the server website (Settings > Connect an app)."
    @State private var found = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let problem {
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill").font(.largeTitle).foregroundColor(.gray)
                    Text(problem).multilineTextAlignment(.center).foregroundColor(.gray)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { UIApplication.shared.open(url) }.buttonStyle(.bordered)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QRCameraView(onCode: handle, onUnavailable: { problem = $0 }).ignoresSafeArea()
                Text(hint)
                    .font(.callout).multilineTextAlignment(.center).foregroundColor(.white)
                    .padding(12).background(.black.opacity(0.6)).cornerRadius(10)
                    .padding(.horizontal, 24).padding(.bottom, 90)
            }
            VStack {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6)).foregroundColor(.white).cornerRadius(10)
                }
                .padding()
                Spacer()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func handle(_ text: String) {
        guard !found else { return }
        guard let url = URL(string: text), let link = ConnectLink(url: url) else {
            hint = "That isn't a SummitRoad connect code. Use the one from the server website's Settings > Connect an app."
            return
        }
        found = true
        onLink(link)
        dismiss()
    }
}
#endif
