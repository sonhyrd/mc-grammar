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

    /// - Parameter mainThreadBlocked: pass `true` only from a caller that is itself parked
    ///   synchronously on the fix for the entire duration `.working` is active — today, only
    ///   `ServiceProvider.fixGrammar`, which calls `fixSync` directly on the main thread. Every
    ///   other caller (the hotkey path's `fixAsync`, and any future one) leaves the main run loop
    ///   free to spin, so the default is `false`: the elapsed-counter timer dispatches its mutation
    ///   to the main queue instead of touching `NSButton` off-main. Defaulting to "not blocked" is
    ///   deliberate — a new call site that forgets this parameter gets the safe behaviour, not a
    ///   silent AppKit-threading violation.
    func setState(_ state: State, mainThreadBlocked: Bool = false) {
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
            startElapsedCounter(mainThreadBlocked: mainThreadBlocked)
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
    /// This is a GCD timer firing on its own background queue, not a main-RunLoop `Timer` —
    /// on the Services path (`ServiceProvider.fixGrammar` calling `fixSync` synchronously on the
    /// main thread) the main run loop is not spinning for the duration of the fix, so a
    /// main-RunLoop `Timer` would never fire. `counterQueue` fires regardless of what the main
    /// thread is doing.
    ///
    /// What the handler does with that tick depends on `mainThreadBlocked`, learned from
    /// `setState` and captured below:
    ///
    /// - **Main thread blocked (Services path only).** The main run loop is not spinning, so
    ///   nothing enqueued with `.main.async` would run until the fix has already finished — too
    ///   late to matter — and there is, by construction, no concurrent main-thread access to
    ///   `button` to race with. So the handler mutates `button.title` and forces
    ///   `displayIfNeeded()` directly from `counterQueue`, off the main thread. AppKit does not
    ///   officially support touching a view from a background thread under any circumstances, so
    ///   this remains a deliberate, narrow exception — but now its precondition (main is actually
    ///   parked) is enforced by the caller passing `mainThreadBlocked: true`, not merely asserted
    ///   in a comment. `ServiceProvider.fixGrammar` is the only call site that does.
    /// - **Main thread free (hotkey path, and any future caller that doesn't opt in).** The
    ///   hotkey path runs `fixSync` on a background queue via `fixAsync`; the main thread is not
    ///   parked, it's free and spinning — so mutating `button` directly from `counterQueue` here
    ///   would race with whatever the main thread is doing to the same `NSButton` at the same
    ///   time. There is no "provably parked" precondition to lean on for this caller, so the
    ///   handler instead dispatches the mutation to `DispatchQueue.main.async` — ordinary,
    ///   correct AppKit usage, and it works fine because main is free to run it promptly.
    ///
    /// VERIFICATION STATUS: the off-main mutation on the blocked-main-thread path was confirmed
    /// in-process — a harness reproduced the exact blocking shape of `ServiceProvider.fixGrammar`
    /// (`setState(.working, mainThreadBlocked: true)` then a real, synchronous `fixSync` call on
    /// the main thread) while a second thread in the same process polled
    /// `statusItem.button.title`, which flipped "⋯" → "⋯ 1s" → "⋯ 2s" *during* the block. That
    /// proves the mutation reaches the live `NSButton` object and is readable back, not silently
    /// dropped or racing to a stale value. It does NOT prove AppKit actually composited the
    /// change to the screen: painting a view's backing store (`displayIfNeeded`) is separate from
    /// the window server picking that up, and the latter can depend on the main run loop cycling,
    /// which is exactly what's blocked on this path. Driving the real Services menu end to end
    /// needs another app's UI on the interactive desktop, which wasn't exercised — this machine's
    /// screen is shared, active, and running unrelated work, so screenshotting or scripting it for
    /// this test was avoided rather than risk capturing that content. If a future check finds the
    /// pixels never actually update on the Services path, the fallback named in ticket #7 is to
    /// drop the `mainThreadBlocked: true` off-main branch entirely and accept hotkey-only ticking.
    private func startElapsedCounter(mainThreadBlocked: Bool) {
        counterLock.lock()
        workStartedAt = Date()
        counterLock.unlock()

        counterLock.lock()
        counterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: counterQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tickElapsedCounter(mainThreadBlocked: mainThreadBlocked)
        }
        counterTimer = timer
        timer.resume()
        counterLock.unlock()
    }

    private func tickElapsedCounter(mainThreadBlocked: Bool) {
        counterLock.lock()
        let startedAt = workStartedAt
        counterLock.unlock()
        guard let startedAt else { return }

        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed >= Self.elapsedCounterThreshold else { return }

        let mutate = { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            button.title = "\(State.working.title) \(Int(elapsed))s"
            button.needsDisplay = true
            button.displayIfNeeded()
        }

        if mainThreadBlocked {
            mutate()
        } else {
            DispatchQueue.main.async(execute: mutate)
        }
    }

    private func stopElapsedCounter() {
        counterLock.lock()
        counterTimer?.cancel()
        counterTimer = nil
        workStartedAt = nil
        counterLock.unlock()
    }
}
