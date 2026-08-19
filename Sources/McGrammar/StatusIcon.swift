import AppKit

/// Owns the menu bar item and its three visual states.
final class StatusIcon {
    static let shared = StatusIcon()

    enum State {
        case idle
        case working
        case error

        var title: String {
            switch self {
            case .idle: return "✒︎"
            case .working: return "⋯"
            case .error: return "✒︎!"
            }
        }
    }

    private var statusItem: NSStatusItem?
    private var revertWork: DispatchWorkItem?

    func install(menu: NSMenu) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = State.idle.title
        item.button?.toolTip = "McGrammar — fix grammar with Claude Code"
        item.menu = menu
        statusItem = item
    }

    func setState(_ state: State) {
        let apply = {
            self.revertWork?.cancel()
            guard let button = self.statusItem?.button else { return }
            button.title = state.title
            // The services path blocks the main thread while Claude thinks, so nudge a synchronous
            // redraw — otherwise the “working” glyph would never actually appear.
            button.needsDisplay = true
            button.displayIfNeeded()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Shows the error glyph, then falls back to idle after a beat.
    func flashError(after seconds: TimeInterval = 3) {
        setState(.error)
        let work = DispatchWorkItem { [weak self] in self?.setState(.idle) }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
