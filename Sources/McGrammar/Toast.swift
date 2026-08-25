import AppKit

/// Small floating HUD used for every user-facing message.
///
/// Deliberately not `UNUserNotificationCenter`: that requires an authorization prompt and behaves
/// unreliably for ad-hoc signed, un-notarized bundles. A borderless panel needs no permission,
/// never steals focus, and cannot disturb the app the user is typing in.
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    /// How long a success message stays up. Short on purpose, and deliberately shorter than the
    /// five seconds errors use: this fires after every successful fix on both trigger paths, so at
    /// error length it would become noise the user learns to look past — costing the signal exactly
    /// when it matters. One home rather than one per path, so the two cannot drift.
    static let successDuration: TimeInterval = 2

    func show(_ message: String, isError: Bool = false, duration: TimeInterval = 3.0) {
        DispatchQueue.main.async { self.present(message, isError: isError, duration: duration) }
    }

    private func present(_ message: String, isError: Bool, duration: TimeInterval) {
        dismissWork?.cancel()
        panel?.orderOut(nil)
        panel = nil

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 360

        let padding: CGFloat = 16
        let labelSize = label.sizeThatFits(NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        let contentSize = NSSize(
            width: min(max(labelSize.width, 180), 360) + padding * 2,
            height: labelSize.height + padding * 2
        )

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        container.material = .hudWindow
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        if isError {
            container.layer?.borderWidth = 1
            container.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        }

        label.frame = NSRect(
            x: padding,
            y: padding,
            width: contentSize.width - padding * 2,
            height: contentSize.height - padding * 2
        )
        container.addSubview(label)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: visible.midX - contentSize.width / 2,
            y: visible.maxY - contentSize.height - 24
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                if self.panel === panel { self.panel = nil }
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
