import Foundation

/// `McGrammar --fix` — reads stdin, prints the correction. Handy for piping and diffing.
///
/// Deliberately not part of `SelfTest`: this is a stdin→stdout filter, not a check, and the two
/// changed for unrelated reasons while they shared a type.
enum CommandLineFix {
    static func run() -> Int32 {
        let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        switch ClaudeRunner.shared.fixSync(input) {
        case .success(let outcome):
            // Written, not printed. The corrected text now carries the input's own trailing
            // whitespace, so `print` would append a second newline and this filter would stop
            // being byte-faithful — which is the whole point of a stdin→stdout filter you can
            // diff against.
            FileHandle.standardOutput.write(Data(outcome.text.utf8))
            return 0
        case .failure(let failure):
            FileHandle.standardError.write(Data("McGrammar: \(failure.description)\n".utf8))
            return 1
        }
    }
}
