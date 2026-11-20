import AppKit
import Quartz

/// Space bar preview with the system Quick Look panel, as in Finder.
@MainActor
final class QuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func toggle(_ files: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        urls = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { urls[index] as NSURL }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 || event.keyCode == 53 { panel.orderOut(nil); return true }
        return false
    }
}
