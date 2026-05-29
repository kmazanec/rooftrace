import SwiftUI

/// Upload progress + terminal outcomes. Success shows a tap-to-copy share URL.
/// Failure offers Retry and Save-bundle-locally.
struct UploadProgressView: View {
    @Bindable var model: CaptureViewModel

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
            Button("Save bundle locally") { /* presents UIDocumentPicker .zip — device path */ }
                .buttonStyle(.bordered)
        }
    }

    private var saved: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 64)).foregroundStyle(.blue)
            Text("Bundle saved").font(.title2).bold()
            Text("You can upload it later from the Files app.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif
