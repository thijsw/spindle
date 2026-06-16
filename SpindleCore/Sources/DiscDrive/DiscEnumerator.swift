import Foundation
import IOKit

/// Finds CD media that are already present (e.g. a disc inserted before the
/// app launched) and identifies the drive hardware behind a medium.
public enum DiscEnumerator {
    /// BSD names (e.g. "disk4") of all whole IOCDMedia objects currently present.
    public static func presentCDMedia() -> [String] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOCDMedia")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var names: [String] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let whole = IORegistryEntryCreateCFProperty(entry, "Whole" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Bool ?? false
            guard whole else { continue }
            if let bsd = IORegistryEntryCreateCFProperty(entry, kIOBSDNameKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                names.append(bsd)
            }
        }
        return names
    }

    /// Walks up the IORegistry from a media object to the device node carrying
    /// the drive's vendor/product identity.
    public static func driveIdentity(forMediaBSDName bsdName: String) -> DriveIdentity? {
        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != 0 else { return nil }

        // The media node's registry name reveals the actual mechanism (e.g.
        // an Apple SuperDrive's media node is "HL-DT-ST DVDRW GX50N Media"),
        // which matters for read-offset suggestions on rebadged drives.
        var nameBuffer = [CChar](repeating: 0, count: 128)
        let mechanism: String?
        if IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS {
            let bytes = nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            mechanism = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: " Media", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else {
            mechanism = nil
        }

        // Ascend until we find a Device Characteristics dictionary.
        // (No defer here: it would release the reassigned parent, not the
        // entry it was registered for.)
        while entry != 0 {
            if let characteristics = IORegistryEntryCreateCFProperty(
                entry, "Device Characteristics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] {
                let identity = DriveIdentity(
                    vendor: (characteristics["Vendor Name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                    product: (characteristics["Product Name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                    revision: (characteristics["Product Revision Level"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                    mechanism: mechanism
                )
                IOObjectRelease(entry)
                return identity
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return nil }
            entry = parent
        }
        return nil
    }
}
