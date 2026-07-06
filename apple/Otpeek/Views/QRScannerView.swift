import SwiftUI
import AVFoundation

#if os(iOS)
struct QRScannerView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var scannedCode: String?
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isTorchOn = false

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerRepresentable(
                    scannedCode: $scannedCode,
                    isTorchOn: $isTorchOn
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()

                    // Scanning Frame
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 250, height: 250)
                        .background(Color.clear)

                    Spacer()

                    // Instructions
                    VStack(spacing: 8) {
                        Text("Scan QR Code")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("Position the QR code within the frame")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(12)
                    .padding(.bottom, 100)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isTorchOn.toggle()
                    } label: {
                        Image(systemName: isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: scannedCode) { oldValue, newValue in
                if let code = newValue {
                    processScannedCode(code)
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {
                    scannedCode = nil
                }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func processScannedCode(_ code: String) {
        appState.lastError = nil
        appState.addFromUri(code)
        if appState.lastError != nil {
            errorMessage = "Invalid OTP QR code. Please scan a valid authenticator QR code."
            showingError = true
        } else {
            dismiss()
        }
    }
}

// MARK: - QR Scanner Representable

struct QRScannerRepresentable: UIViewControllerRepresentable {
    @Binding var scannedCode: String?
    @Binding var isTorchOn: Bool

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.setTorch(on: isTorchOn)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, QRScannerDelegate {
        let parent: QRScannerRepresentable

        init(_ parent: QRScannerRepresentable) {
            self.parent = parent
        }

        func didScanCode(_ code: String) {
            parent.scannedCode = code
        }
    }
}

// MARK: - QR Scanner View Controller

protocol QRScannerDelegate: AnyObject {
    func didScanCode(_ code: String)
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        captureSession = session

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
    }

    func startScanning() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    func stopScanning() {
        captureSession?.stopRunning()
    }

    func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video),
              device.hasTorch else { return }

        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                       didOutput metadataObjects: [AVMetadataObject],
                       from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue else { return }

        stopScanning()
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        delegate?.didScanCode(stringValue)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }
}

#Preview {
    QRScannerView()
        .environmentObject(AppState())
}
#else
// macOS placeholder
struct QRScannerView: View {
    var body: some View {
        Text("QR Scanner is not available on macOS")
    }
}
#endif
