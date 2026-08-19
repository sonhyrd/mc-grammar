import AppKit
import Darwin

// A child that exits before reading stdin would otherwise take the whole app down with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
        McGrammar — fix grammar in any macOS app using your local Claude Code CLI.

        Usage:
          McGrammar              Launch the menu bar app (⌃⌥G, plus the Services menu item)
          McGrammar --selftest   Run headless checks: CLI discovery, permissions, a real fix
          McGrammar --fix        Read text from stdin, print the corrected text
          McGrammar --help       Show this message
        """)
    exit(0)
}

if arguments.contains("--selftest") {
    exit(SelfTest.run())
}

if arguments.contains("--fix") {
    exit(SelfTest.fixStdin())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
