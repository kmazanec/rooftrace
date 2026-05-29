import Foundation

/// Writes a capture bundle to a single `.zip` on disk for the local-save
/// recovery path (when the upload cannot be completed).
///
/// The bundle layout inside the archive mirrors the multipart upload: a
/// `session.json` manifest plus the per-capture photo/depth files and the world
/// mesh, all flat at the archive root. The files are first laid down into a temp
/// directory, then that directory is zipped via `NSFileCoordinator`'s
/// `.forUploading` coordination (Foundation-only — no third-party zip
/// dependency). The resulting `.zip` is suitable for export through
/// `UIDocumentPickerViewController` so the user can hand it to support or retry
/// the upload later from the Files app.
struct BundleArchiver {
    enum ArchiveError: Error, Equatable {
        case writeFailed
        case zipFailed
    }

    /// Writes `parts` to a temporary directory and zips it. Returns the URL of
    /// the created `.zip`. The caller owns the file (and is responsible for
    /// deleting it once exported / no longer needed).
    func archive(parts: [MultipartPart], named name: String) throws -> URL {
        let fm = FileManager.default
        let stageRoot = fm.temporaryDirectory
            .appendingPathComponent("rooftrace-bundle-\(UUID().uuidString)", isDirectory: true)
        let contentDir = stageRoot.appendingPathComponent(name, isDirectory: true)
        defer { try? fm.removeItem(at: stageRoot) }

        do {
            try fm.createDirectory(at: contentDir, withIntermediateDirectories: true)
            for part in parts {
                let fileURL = contentDir.appendingPathComponent(part.filename)
                try part.data.write(to: fileURL)
            }
        } catch {
            throw ArchiveError.writeFailed
        }

        let destination = fm.temporaryDirectory.appendingPathComponent("\(name).zip")
        try? fm.removeItem(at: destination)

        var coordinatorError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: contentDir,
                               options: [.forUploading],
                               error: &coordinatorError) { zippedURL in
            // `zippedURL` is a system-generated temporary `.zip`; move it to our
            // stable destination before the coordinator cleans it up.
            do {
                try fm.moveItem(at: zippedURL, to: destination)
            } catch {
                moveError = error
            }
        }

        if coordinatorError != nil || moveError != nil {
            throw ArchiveError.zipFailed
        }
        return destination
    }
}
