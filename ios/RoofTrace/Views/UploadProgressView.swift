import SwiftUI
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Upload progress + terminal outcomes. Success shows a tap-to-copy share URL.
/// Failure offers Retry and Save-bundle-locally.
struct UploadProgressView: View {
    @Bindable var model: CaptureViewModel
    @State private var isSavingBundle = false
    @State private var presentExporter = false

    var body: some View {
        VStack(spacing: 24) {
            switch model.state {
            case .uploading:
                uploading
            case .uploadComplete:
                complete
            case .uploadFailed:
                failed
            case .bundleSaved:
                saved
            default:
                EmptyView()
            }
            Spacer()
        }
        .padding()
    }

    private var uploading: some View {
        VStack(spacing: 16) {
            Text("Uploading capture…").font(.title2).bold()
            ProgressView(value: model.uploadProgress)
                .progressViewStyle(.linear)
            Text("\(Int(model.uploadProgress * 100))%").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var complete: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64)).foregroundStyle(.green)
            Text("Upload complete").font(.title2).bold()
            if let url = model.shareURL {
                Text("View results at")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = url
                    #endif
                } label: {
                    Label(url, systemImage: "doc.on.doc")
                        .font(.footnote)
                }
            }
        }
    }

    private var failed: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64)).foregroundStyle(.red)
            Text("Upload failed").font(.title2).bold()
            if let message = model.errorMessage {
                Text(message).font(.subheadline)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Retry") { Task { await model.retryUpload() } }
                .buttonStyle(.borderedProminent)
                .disabled(isSavingBundle)
            Button {
                Task {
                    isSavingBundle = true
                    await model.saveBundleLocally()
                    isSavingBundle = false
                }
            } label: {
                if isSavingBundle {
                    ProgressView()
                } else {
                    Text("Save bundle locally")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSavingBundle)
        }
    }

    private var saved: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 64)).foregroundStyle(.blue)
            Text("Bundle saved").font(.title2).bold()
            Text("Export it now, or find it later to upload from the Files app.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #if canImport(UIKit)
            if model.savedBundleURL != nil {
                Button("Export bundle…") { presentExporter = true }
                    .buttonStyle(.borderedProminent)
            }
            #endif
        }
        #if canImport(UIKit)
        // Auto-present the export sheet as soon as the bundle is ready, and also
        // let the user re-open it via the button above.
        .onAppear { if model.savedBundleURL != nil { presentExporter = true } }
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
