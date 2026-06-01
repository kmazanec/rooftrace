import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Upload progress + terminal outcomes. Success shows a tap-to-copy share URL.
/// Failure offers Retry and Save-bundle-locally.
struct UploadProgressView: View {
    @Bindable var model: CaptureViewModel
    @State private var presentExporter = false
    @State private var didCopy = false

    var body: some View {
        ZStack {
            Color.CC.chalk.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                switch model.state {
                case .uploading:
                    uploading
                case .uploadComplete:
                    complete
                case .uploadFailed:
                    failed
                case .bundleSaved:
                    saved
                case .setupCheck, .capturePrompt, .lidarUnsupported:
                    EmptyView()
                }
                Spacer()
            }
            .padding(20)
        }
    }

    private var uploading: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                eyebrow: "Upload",
                title: "Sending scan",
                subtitle: "Keep the app open while the capture bundle uploads."
            )
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    SegmentedProgress(fraction: 1, segmentCount: CaptureSessionState.promptCount)
                    ProgressView(value: 0.65)
                        .tint(Color.CC.blue)
                    Text("Assembling photos, depth maps, and mesh")
                        .font(.RoofTrace.bodyMedium)
                        .foregroundStyle(Color.CC.ink75)
                }
            }
        }
    }

    private var complete: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                eyebrow: "Upload",
                title: "Upload complete",
                subtitle: "Returning to the job while the measurement pipeline processes the new scan."
            )
            Card {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(Color.Brand.orange)
                    if let url = model.shareURL {
                        GhostButton(title: didCopy ? "Copied" : "Copy results URL", systemImage: "doc.on.doc") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = url
                            #endif
                            didCopy = true
                        }
                        .accessibilityLabel("Copy results URL")
                        if didCopy {
                            Text(url)
                                .font(.RoofTrace.label)
                                .foregroundStyle(Color.CC.ink55)
                                .lineLimit(2)
                                .task(id: didCopy) {
                                    try? await Task.sleep(for: .seconds(2))
                                    didCopy = false
                                }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                eyebrow: "Upload",
                title: "Upload failed",
                subtitle: "Retry the upload or save the full capture bundle locally."
            )
            if let message = model.errorMessage {
                InlineErrorBlock(message: message)
            }
            PrimaryButton(title: "Try again", isDisabled: model.isSavingBundle) {
                Task { await model.retryUpload() }
            }
            Button(action: {
                Task { await model.saveBundleLocally() }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text(model.isSavingBundle ? "Saving" : "Save bundle locally")
                        .font(.RoofTrace.button)
                }
                .foregroundStyle(Color.CC.orangeHigh)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .background(Color.CC.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.CC.orange.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.isSavingBundle)
        }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                eyebrow: "Upload",
                title: "Bundle saved",
                subtitle: "Export it now, or find it later to upload from the Files app."
            )
            #if canImport(UIKit)
            if model.savedBundleURL != nil {
                PrimaryButton(title: "Export bundle") { presentExporter = true }
            }
            #endif
        }
        #if canImport(UIKit)
        // Auto-present the export sheet once when the bundle URL becomes non-nil.
        // .task(id:) re-fires only when the id value changes — unlike .onAppear it
        // won't re-present the sheet every time the view comes back to the foreground.
        .task(id: model.savedBundleURL) { if model.savedBundleURL != nil { presentExporter = true } }
        .sheet(isPresented: $presentExporter) {
            if let url = model.savedBundleURL {
                DocumentExporter(url: url)
            }
        }
        #endif
    }
}

#if canImport(UIKit)
/// Presents `UIDocumentPickerViewController` in export mode so the user can move
/// the saved `.zip` capture bundle out of the app sandbox (to Files, iCloud
/// Drive, AirDrop, etc.) for a later manual upload.
struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
#endif
