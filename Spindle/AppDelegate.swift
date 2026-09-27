import AppKit

/// Guards against quitting while a disc is mid-rip.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running model, set by `AppModel.start()`.
    static weak var activeModel: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.activeModel?.hasActiveJobs == true else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A disc is still being processed"
        alert.informativeText = "Quitting now abandons the rip in progress. Finished discs are unaffected."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.activeModel?.settings.flush()
    }
}
