import SwiftUI
import UIKit

/// Native share sheet for exporting session files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    var onDismiss: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onDismiss?() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
