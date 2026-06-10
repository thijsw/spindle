import AppKit

/// Guards against quitting while a disc is mid-rip.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Wired up by AppModel at launch.
    nonisolated(unsafe) static var hasActiveWork: @MainActor () -> Bool = { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated(Self.hasActiveWork) else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A disc is still being processed"
        alert.informativeText = "Quitting now abandons the rip in progress. Finished discs are unaffected."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit Anyway")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
