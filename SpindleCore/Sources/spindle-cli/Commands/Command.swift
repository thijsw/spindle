import Foundation

enum Command: String, CaseIterable {
    case detect, drives, toc, discid, identify, rip, encode
    case scanOffset = "scan-offset"
    case push

    static var usage: String {
        """
        usage: spindle-cli <command>

        commands:
        \(allCases.map(\.help).joined(separator: "\n"))

        [disk] is a BSD name like disk4; defaults to the first CD medium found.
        """
    }

    var help: String {
        switch self {
        case .detect: "  detect            watch for disc insertions/removals (Ctrl-C to stop)"
        case .drives: "  drives            list present CD media and drive identity"
        case .toc: "  toc [disk]        read and print the table of contents"
        case .discid: "  discid [disk]     compute the MusicBrainz DiscID and TOC string"
        case .identify: IdentifyCommand.help
        case .rip: RipCommand.help
        case .encode: EncodeCommand.help
        case .scanOffset: ScanOffsetCommand.help
        case .push: PushCommand.help
        }
    }

    func run(_ args: ArraySlice<String>) async throws {
        switch self {
        case .detect: try await DiscCommands.detect()
        case .drives: DiscCommands.drives()
        case .toc: try await DiscCommands.toc(args)
        case .discid: try await DiscCommands.discid(args)
        case .identify: try await IdentifyCommand.run(args)
        case .rip: try await RipCommand.run(args)
        case .encode: try await EncodeCommand.run(args)
        case .scanOffset: try await ScanOffsetCommand.run(args)
        case .push: try await PushCommand.run(args)
        }
    }
}
