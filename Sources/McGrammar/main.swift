import AppKit
import Darwin

// A child that exits before reading stdin would otherwise take the whole app down with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
        McGrammar — fix grammar in any macOS app using your local Claude Code CLI.

        Usage:
          McGrammar              Launch the menu bar app (⌃⌥D, plus the Services menu item)
          McGrammar --selftest   Run headless checks: CLI discovery, permissions, a real fix
          McGrammar --fix        Read text from stdin, write the corrected text.
                                  Add --proofread (default) or --polish to choose a preset.
          McGrammar --fixtures   Run the live accuracy suite against the pinned model (costs
                                  money, needs a login; not part of --selftest or swift test)
          McGrammar --help       Show this message
        """)
    exit(0)
}

if arguments.contains("--selftest") {
    exit(SelfTest.run())
}

if arguments.contains("--fix") {
    exit(CommandLineFix.run(preset: Preset.fromArguments(arguments, default: .proofread)))
}

if arguments.contains("--fixtures") {
    exit(Fixtures.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// The activation policy is set once, in AppDelegate.applicationDidFinishLaunching.
application.run()
