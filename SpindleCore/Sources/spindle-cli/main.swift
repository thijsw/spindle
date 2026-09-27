import Foundation

// Debug/development CLI: exercises every subsystem headless, against a real
// drive or (identify/encode --toc) without one. One file per command under
// Commands/; this file only dispatches.

let arguments = CommandLine.arguments.dropFirst()
guard let name = arguments.first else {
    print(Command.usage)
    exit(0)
}
guard let command = Command(rawValue: name) else {
    print(Command.usage)
    exit(64)
}
try await command.run(arguments.dropFirst())
