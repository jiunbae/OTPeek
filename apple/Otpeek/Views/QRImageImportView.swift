import SwiftUI
import Vision
import PhotosUI

#if os(macOS)
import AppKit
import ScreenCaptureKit
#else
import UIKit
#endif

struct QRImageImportView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var detectedCode: String?
    @State private var errorMessage: String?
    @State private var isProcessing = false

    #if os(macOS)
    @State private var isDragging = false
    @State private var importedImage: NSImage?
    @State private var screenPicker: ScreenQRPicker?
    #else
    @State private var importedImage: UIImage?
    @State private var selectedItem: PhotosPickerItem?
    #endif

    var body: some View {
        #if os(macOS)
        macOSContent
        #else
        NavigationStack {
            iOSContent
                .navigationTitle("Import QR Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
        }
        #endif
    }

    // MARK: - macOS Content

    #if os(macOS)
    private var macOSContent: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Import QR Code")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }
            .padding(.bottom)

            // Drop Zone
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
                    .foregroundColor(isDragging ? .blue : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDragging ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.05))
                    )

                VStack(spacing: 12) {
                    if screenPicker != nil {
                        ProgressView("Waiting for screen capture…")
                    } else if isProcessing {
                        ProgressView("Processing...")
                    } else if let image = importedImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("Drop QR code image here")
                            .font(.headline)

                        Text("or")
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("Choose File...") {
                            selectImageFile()
                        }

                        Button("Paste from Clipboard") {
                            pasteFromClipboard()
                        }

                        Button("Import from Screen…") {
                            importFromScreen()
                        }
                    }
                    .disabled(isProcessing || screenPicker != nil)
                }
                .padding(12)
            }
            .frame(height: 250)
            .onDrop(of: [.image, .fileURL], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
            }

            resultView
                .disabled(isProcessing || screenPicker != nil)

            Spacer()
        }
        .padding()
        .frame(width: 450, height: 450)
        .onDisappear {
            screenPicker?.stop()
            screenPicker = nil
        }
    }
    #endif

    // MARK: - iOS Content

    #if os(iOS)
    private var iOSContent: some View {
        VStack(spacing: 24) {
            // Image Preview or Picker
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.1))

                if let image = importedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else if isProcessing {
                    ProgressView("Processing...")
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 56))
                            .foregroundColor(.secondary)

                        Text("Select a QR code image")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 280)

            // Photo Picker
            PhotosPicker(selection: $selectedItem, matching: .images) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .onChange(of: selectedItem) { _, newItem in
                loadImage(from: newItem)
            }

            resultView

            Spacer()
        }
        .padding()
    }
    #endif

    // MARK: - Result View

    @ViewBuilder
    private var resultView: some View {
        if let code = detectedCode {
            VStack(alignment: .leading, spacing: 8) {
                Label("QR Code Detected", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)

                if let account = try? parseOtpauthUri(uri: code, nowMs: Int64(Date().timeIntervalSince1970 * 1000)) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.issuerText.isEmpty ? "Unknown" : account.issuerText)
                                .font(.headline)
                            Text(account.accountName)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Add Account") {
                            appState.addFromUri(code)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
                } else {
                    Text("Invalid OTP QR code format")
                        .foregroundColor(.red)
                }
            }
        }

        if let error = errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        }
    }

    // MARK: - macOS Methods

    #if os(macOS)
    private func importFromScreen() {
        guard !SCContentSharingPicker.shared.isActive else {
            errorMessage = "The screen picker is already open."
            return
        }

        let picker = ScreenQRPicker()
        screenPicker = picker
        picker.present { result in
            screenPicker = nil

            switch result {
            case .success(let image?):
                importedImage = nil
                detectedCode = nil
                errorMessage = nil
                isProcessing = true
                performQRDetection(on: image)
            case .success(nil):
                break
            case .failure(let error):
                importedImage = nil
                detectedCode = nil
                if (error as? SCStreamError)?.code == .userDeclined {
                    errorMessage = "Screen capture permission was declined. Choose or paste a QR image to import it."
                } else {
                    errorMessage = "Couldn’t capture the selected screen content. Try again or import an image."
                }
            }
        }
    }

    private func selectImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            loadImage(from: url)
        }
    }

    private func pasteFromClipboard() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
            imageLoadFailed("No image found in clipboard")
            return
        }

        importedImage = image
        detectQRCode(in: image)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard screenPicker == nil, !isProcessing, let provider = providers.first else {
            return false
        }

        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            isProcessing = true
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap {
                    URL(dataRepresentation: $0, relativeTo: nil)
                }
                DispatchQueue.main.async {
                    if let url {
                        loadImage(from: url)
                    } else {
                        imageLoadFailed()
                    }
                }
            }
            return true
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            isProcessing = true
            provider.loadObject(ofClass: NSImage.self) { image, _ in
                DispatchQueue.main.async {
                    if let nsImage = image as? NSImage {
                        importedImage = nsImage
                        detectQRCode(in: nsImage)
                    } else {
                        imageLoadFailed()
                    }
                }
            }
            return true
        }

        return false
    }

    private func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            imageLoadFailed()
            return
        }

        importedImage = image
        detectQRCode(in: image)
    }

    private func imageLoadFailed(_ message: String = "Failed to load image") {
        isProcessing = false
        importedImage = nil
        detectedCode = nil
        errorMessage = message
    }

    private func detectQRCode(in image: NSImage) {
        isProcessing = true
        errorMessage = nil
        detectedCode = nil

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = "Failed to process image"
            isProcessing = false
            return
        }

        performQRDetection(on: cgImage)
    }
    #endif

    // MARK: - iOS Methods

    #if os(iOS)
    private func loadImage(from item: PhotosPickerItem?) {
        guard let item = item else { return }

        isProcessing = true
        errorMessage = nil
        detectedCode = nil

        item.loadTransferable(type: Data.self) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    if let data = data, let uiImage = UIImage(data: data) {
                        self.importedImage = uiImage
                        self.detectQRCode(in: uiImage)
                    } else {
                        self.errorMessage = "Failed to load image"
                        self.isProcessing = false
                    }
                case .failure(let error):
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }

    private func detectQRCode(in image: UIImage) {
        guard let cgImage = image.cgImage else {
            errorMessage = "Failed to process image"
            isProcessing = false
            return
        }

        performQRDetection(on: cgImage)
    }
    #endif

    // MARK: - Shared QR Detection

    private func performQRDetection(on cgImage: CGImage) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let payload = request.results?.first?.payloadStringValue
                DispatchQueue.main.async {
                    isProcessing = false
                    detectedCode = payload
                    if payload == nil {
                        errorMessage = "No QR code found in image"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = "Detection failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

#if os(macOS)
@MainActor
private final class ScreenQRPicker: NSObject, SCContentSharingPickerObserver {
    private let picker = SCContentSharingPicker.shared
    private var previousConfiguration: SCContentSharingPickerConfiguration?
    private var completion: ((Result<CGImage?, Error>) -> Void)?
    private var captureTask: Task<Void, Never>?

    func present(completion: @escaping (Result<CGImage?, Error>) -> Void) {
        self.completion = completion
        previousConfiguration = picker.defaultConfiguration

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func stop() {
        guard let previousConfiguration else { return }
        completion = nil
        captureTask?.cancel()
        captureTask = nil
        picker.remove(self)
        picker.isActive = false
        picker.defaultConfiguration = previousConfiguration
        self.previousConfiguration = nil
    }

    private func finish(_ result: Result<CGImage?, Error>) {
        let callback = completion
        stop()
        callback?(result)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        guard stream == nil else { return }
        Task { @MainActor in
            finish(.success(nil))
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            finish(.failure(error))
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        guard stream == nil else { return }
        Task { @MainActor in
            capture(using: filter)
        }
    }

    private func capture(using filter: SCContentFilter) {
        guard completion != nil, captureTask == nil else { return }

        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false

        captureTask = Task {
            do {
                try Task.checkCancellation()
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                try Task.checkCancellation()
                finish(.success(image))
            } catch where Task.isCancelled {
                return
            } catch let error as SCStreamError where error.code == .userStopped {
                finish(.success(nil))
            } catch {
                finish(.failure(error))
            }
        }
    }
}
#endif

#Preview {
    QRImageImportView()
        .environmentObject(AppState())
}
