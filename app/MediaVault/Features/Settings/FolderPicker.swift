import SwiftUI
import UniformTypeIdentifiers

/// Wraps `UIDocumentPickerViewController` for choosing the library folder.
///
/// The picked URL is reported straight back; persisting it is the caller's job, so
/// this stays a pure UI adapter with no knowledge of bookmarks or storage.
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        nonisolated func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            // UIKit guarantees this delegate call is on the main thread; the
            // annotation is what tells the compiler so.
            MainActor.assumeIsolated { onPick(url) }
        }
    }
}
