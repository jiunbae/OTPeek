import SwiftUI
import Vision
import PhotosUI

#if os(macOS)
import AppKit
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

                if let image = importedImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                } else if isProcessing {
                    ProgressView("Processing...")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("Drop QR code image here")
                            .font(.headline)

                        Text("or")
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Button("Choose File...") {
                                selectImageFile()
                            }

                            Button("Paste from Clipboard") {
                                pasteFromClipboard()
                            }
                        }
                    }
                }
            }
            .frame(height: 250)
            .onDrop(of: [.image, .fileURL], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
            }

            resultView

            Spacer()
        }
        .padding()
        .frame(width: 450, height: 450)
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
            errorMessage = "No image found in clipboard"
            return
        }

        importedImage = image
        detectQRCode(in: image)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        loadImage(from: url)
                    }
                }
            }
            return true
        } else if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { image, error in
                if let nsImage = image as? NSImage {
                    DispatchQueue.main.async {
                        self.importedImage = nsImage
                        self.detectQRCode(in: nsImage)
                    }
                }
            }
            return true
        }

        return false
    }

    private func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "Failed to load image"
            return
        }

        importedImage = image
        detectQRCode(in: image)
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
        let request = VNDetectBarcodesRequest { request, error in
            DispatchQueue.main.async {
                isProcessing = false

                if let error = error {
                    errorMessage = "Detection failed: \(error.localizedDescription)"
                    return
                }

                guard let results = request.results as? [VNBarcodeObservation],
                      let firstQR = results.first(where: { $0.symbology == .qr }),
                      let payload = firstQR.payloadStringValue else {
                    errorMessage = "No QR code found in image"
                    return
                }

                detectedCode = payload
            }
        }

        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }
}

#Preview {
    QRImageImportView()
        .environmentObject(AppState())
}
