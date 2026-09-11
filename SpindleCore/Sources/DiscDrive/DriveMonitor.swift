import DiskArbitration
import Foundation

public enum DriveEvent: Sendable, Equatable {
    /// A CD medium appeared in a drive.
    case discAppeared(bsdName: String)
    /// The medium went away (ejected or drive unplugged).
    case discDisappeared(bsdName: String)
}

/// Watches for CD media using DiskArbitration and controls mounting/ejection.
///
/// While a disc is "held" (`hold(bsdName:)`), the monitor dissents cddafs
/// mount attempts so macOS does not auto-mount the audio CD we are reading
/// raw, and unmounts it if it was already mounted.
public final class DriveMonitor: @unchecked Sendable {
    private let session: DASession
    private let queue = DispatchQueue(label: "nl.huell.spindle.drivemonitor")
    private var heldDiscs: Set<String> = [] // guarded by queue
    private var continuation: AsyncStream<DriveEvent>.Continuation?

    /// Disc appearance/disappearance events. Single-consumer.
    public private(set) lazy var events: AsyncStream<DriveEvent> = {
        AsyncStream { continuation in
            queue.async { self.continuation = continuation }
        }
    }()

    public init() throws {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw DiscDriveError.ioctlFailed(name: "DASessionCreate", code: -1)
        }
        self.session = session
        DASessionSetDispatchQueue(session, queue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let cdMatch: CFDictionary = [
            kDADiskDescriptionMediaKindKey as String: "IOCDMedia",
            kDADiskDescriptionMediaWholeKey as String: true,
        ] as CFDictionary

        DARegisterDiskAppearedCallback(session, cdMatch, { disk, context in
            guard let context else { return }
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
            if let name = DriveMonitor.bsdName(of: disk) {
                monitor.continuation?.yield(.discAppeared(bsdName: name))
            }
        }, context)

        DARegisterDiskDisappearedCallback(session, cdMatch, { disk, context in
            guard let context else { return }
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
            if let name = DriveMonitor.bsdName(of: disk) {
                monitor.continuation?.yield(.discDisappeared(bsdName: name))
            }
        }, context)

        // Dissent mounts of any partition of a held disc (the cddafs volume
        // appears on a slice like disk4s0 while we hold disk4).
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context -> Unmanaged<DADissenter>? in
            guard let context else { return nil }
            let monitor = Unmanaged<DriveMonitor>.fromOpaque(context).takeUnretainedValue()
            guard let name = DriveMonitor.bsdName(of: disk) else { return nil }
            let isHeld = monitor.heldDiscs.contains { name == $0 || name.hasPrefix($0 + "s") }
            guard isHeld else { return nil }
            let dissenter = DADissenterCreate(
                kCFAllocatorDefault,
                DAReturn(kDAReturnExclusiveAccess),
                "Spindle is ripping this disc" as CFString
            )
            return Unmanaged.passRetained(dissenter)
        }, context)
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
        continuation?.finish()
    }

    private static func bsdName(of disk: DADisk) -> String? {
        DADiskGetBSDName(disk).map { String(cString: $0) }
    }

    private func disk(forBSDName bsdName: String) -> DADisk? {
        DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName)
    }

    /// Marks a disc as in use by Spindle (future mount attempts are dissented)
    /// and unmounts any already-mounted volumes on it.
    public func hold(bsdName: String) async throws {
        queue.sync { _ = heldDiscs.insert(bsdName) }
        try await unmountVolumes(ofWholeDisk: bsdName)
    }

    /// Releases a previously held disc.
    public func release(bsdName: String) {
        queue.sync { _ = heldDiscs.remove(bsdName) }
    }

    /// The disk, or nil if DiskArbitration no longer knows about the media
    /// (it was ejected behind our back). `DADiskCreateFromBSDName` happily
    /// hands back an object for a device that is gone; only the description
    /// tells them apart, and operating on such a disk dissents with
    /// `kDAReturnBadArgument`.
    private func presentDisk(forBSDName bsdName: String) -> DADisk? {
        guard let disk = disk(forBSDName: bsdName),
              DADiskCopyDescription(disk) != nil else { return nil }
        return disk
    }

    /// Unmounts every mounted volume belonging to the given whole disk.
    private func unmountVolumes(ofWholeDisk bsdName: String) async throws {
        guard let disk = presentDisk(forBSDName: bsdName) else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = DACallbackBox(continuation: cont)
            DADiskUnmount(
                disk,
                DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                { _, dissenter, context in
                    DACallbackBox.complete(context: context, dissenter: dissenter, operation: .unmount)
                },
                Unmanaged.passRetained(box).toOpaque()
            )
        }
    }

    /// Ejects the disc (volumes must already be unmounted). A disc that has
    /// already left the drive is not an error — the goal is already met.
    public func eject(bsdName: String) async throws {
        release(bsdName: bsdName)
        guard let disk = presentDisk(forBSDName: bsdName) else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = DACallbackBox(continuation: cont)
            DADiskEject(
                disk,
                DADiskEjectOptions(kDADiskEjectOptionDefault),
                { _, dissenter, context in
                    DACallbackBox.complete(context: context, dissenter: dissenter, operation: .eject)
                },
                Unmanaged.passRetained(box).toOpaque()
            )
        }
    }
}

/// A DiskArbitration request Spindle makes on a disc.
enum DiskArbitrationOperation: String, Sendable {
    case unmount
    case eject
}

public struct DiskArbitrationError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let status: Int32
    public let reason: String?

    public var description: String {
        "Disk \(operation) failed (status 0x\(String(UInt32(bitPattern: status), radix: 16)))"
            + (reason.map { ": \($0)" } ?? "")
    }
}

/// Bridges a DiskArbitration completion callback to a checked continuation.
private final class DACallbackBox {
    let continuation: CheckedContinuation<Void, Error>
    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    static func complete(
        context: UnsafeMutableRawPointer?,
        dissenter: DADissenter?,
        operation: DiskArbitrationOperation
    ) {
        guard let context else { return }
        let box = Unmanaged<DACallbackBox>.fromOpaque(context).takeRetainedValue()
        guard let dissenter else { box.continuation.resume(); return }
        if let error = dissentError(
            operation: operation,
            status: DADissenterGetStatus(dissenter),
            reason: DADissenterGetStatusString(dissenter) as String?
        ) {
            box.continuation.resume(throwing: error)
        } else {
            box.continuation.resume()
        }
    }
}

/// Maps a DiskArbitration dissent onto an error, or nil when the dissent means
/// the operation's goal already holds.
///
/// `DAReturn` is a signed `mach_error_t`, so every dissent code (0xF8DA00xx) is
/// NEGATIVE when seen as an `Int32` — never feed it to `UInt32(_:)`, that
/// conversion traps and takes the whole app down.
func dissentError(
    operation: DiskArbitrationOperation,
    status: DAReturn,
    reason: String?
) -> DiskArbitrationError? {
    // Nothing was mounted, so there is nothing left to unmount.
    if operation == .unmount, Int(status) == kDAReturnNotMounted { return nil }
    return DiskArbitrationError(operation: operation.rawValue, status: status, reason: reason)
}
