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

    /// A fix under this long produces no visible change at all. See the correcting comment on
    /// issue #7 (and #1): re-measured end-to-end wall clock puts a normal fix at 2.4–2.8s, not
    /// the ~0.84s originally assumed. A 3s threshold would therefore fire on ordinary
    /// corrections — exactly the visual noise the counter exists to avoid. 5s clears a long
    /// paragraph with headroom and still appears well before the 10s Services / 15s hotkey
    /// timeouts ticket #6 introduces.
    static let elapsedCounterThreshold: TimeInterval = 5

    private var statusItem: NSStatusItem?
    private var revertWork: DispatchWorkItem?

    // MARK: - Elapsed-seconds counter

    // Deliberately a plain serial GCD queue, not the main queue and not a RunLoop-based Timer.
    // See the comment on startElapsedCounter() for why.
    private let counterQueue = DispatchQueue(label: "com.zernonia.mcgrammar.status-counter")
    private var counterTimer: DispatchSourceTimer?
    private var workStartedAt: Date?
    // Guards workStartedAt / counterTimer, which are written from whatever thread calls
    // setState() (main, for both call sites today) and read from counterQueue's timer handler.
    private let counterLock = NSLock()

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

        if state == .working {
            startElapsedCounter()
        } else {
            stopElapsedCounter()
        }
    }

    /// Shows the error glyph, then falls back to idle after a beat.
    func flashError(after seconds: TimeInterval = 3) {
        setState(.error)
        let work = DispatchWorkItem { [weak self] in self?.setState(.idle) }
        revertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Ticks "⋯ Ns" onto the working glyph once a fix has run past `elapsedCounterThreshold`,
    /// so a normal fix produces zero visual noise and a stuck one gets a fault indicator instead
    /// of a static glyph that never changes.
    ///
    /// This has to be a GCD timer firing on its own background queue, not
    /// `DispatchQueue.main.async` and not a `Timer` scheduled on the main `RunLoop`. The Services
    /// path (`ServiceProvider.fixGrammar`) calls `fixSync` synchronously on the main thread, which
    /// means the main run loop is not spinning for the entire duration of a fix: nothing enqueued
    /// with `.main.async` runs until the fix has already finished (too late to matter), and a
    /// main-RunLoop `Timer` never fires at all. So the handler below mutates `button.title` and
    /// forces `displayIfNeeded()` directly from `counterQueue`, off the main thread — the same
    /// "nudge a synchronous redraw" trick `setState` already uses, just invoked from a thread that
    /// isn't blocked.
    ///
    /// AppKit does not officially support touching a view from a background thread under any
    /// circumstances, so this is a deliberate, narrow exception: the main thread is provably
    /// parked inside a synchronous `Process.waitUntilExit` call for the entire window this timer
    /// is armed, so there is no concurrent main-thread access to `button` to race with.
    ///
    /// VERIFICATION STATUS: confirmed in-process, not yet confirmed on-screen through a live
    /// Services-menu invocation. With the threshold temporarily lowered, a harness reproduced the
    /// exact blocking shape of `ServiceProvider.fixGrammar` — `setState(.working)` then a real,
    /// synchronous `ClaudeRunner.fixSync` call on the main thread — while a second thread in the
    /// same process polled `statusItem.button.title`. That poller observed the title flip from
    /// "⋯" to "⋯ 1s" to "⋯ 2s" *during* the block, proving the off-main mutation reaches the
    /// live `NSButton` object and is readable back, not silently dropped or racing to a stale
    /// value. What that harness does NOT prove is that AppKit actually composited the change to
    /// the screen: painting a view's backing store (`displayIfNeeded`) is separate from the
    /// window server picking that up, and the latter can depend on the main run loop cycling,
    /// which is exactly what's blocked here. Driving the real Services menu end to end needs
    /// another app's UI on the interactive desktop, which wasn't exercised — this machine's
    /// screen is shared, active, and running unrelated work, so screenshotting or scripting it
    /// for this test was avoided rather than risk capturing that content. If a future check finds
    /// the pixels never actually update on the Services path, the fallback named in ticket #7 is
    /// to gate the mutation in this handler on `Thread.isMainThread` and accept hotkey-only
    /// ticking.
    private func startElapsedCounter() {
        counterLock.lock()
        workStartedAt = Date()
        counterLock.unlock()

        counterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: counterQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tickElapsedCounter()
        }
        counterTimer = timer
        timer.resume()
    }

    private func tickElapsedCounter() {
        counterLock.lock()
        let startedAt = workStartedAt
        counterLock.unlock()
        guard let startedAt else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= Self.elapsedCounterThreshold else { return }
        guard let button = statusItem?.button else { return }

        button.title = "\(State.working.title) \(Int(elapsed))s"
        button.needsDisplay = true
        button.displayIfNeeded()
    }

    private func stopElapsedCounter() {
        counterTimer?.cancel()
        counterTimer = nil
        counterLock.lock()
        workStartedAt = nil
        counterLock.unlock()
    }
}
