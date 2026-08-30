import AppKit
import Foundation
import Darwin

// A child that exits before reading stdin would otherwise take the whole app down with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
        McGrammar — fix grammar in any macOS app using your local Claude Code CLI.

        Usage:
          McGrammar              Launch the menu bar app (⌃⌥D, ⌃⌥⇧D and ⌃⌥T, plus the
                                  matching Services menu items)
          McGrammar --selftest   Run headless checks: CLI discovery, permissions, a real fix
          McGrammar --fix        Read text from stdin, write the edited text. Uses the same
                                  preset as the ⌃⌥D gesture unless you pass --polish or
                                  --proofread.
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
    switch Preset.fromArguments(arguments, default: .standard) {
    case .selected(let preset):
        exit(CommandLineFix.run(preset: preset))
    case let selection:
        // Refused rather than defaulted: --fix overwrites whatever it is given, so guessing which
        // preset was meant would rewrite the user's text under one they did not ask for.
        FileHandle.standardError.write(Data("McGrammar: \(selection.errorDescription ?? "")\n".utf8))
        exit(2)
    }
}

if arguments.contains("--fixtures") {
    exit(Fixtures.run())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// The activation policy is set once, in AppDelegate.applicationDidFinishLaunching.
application.run()
