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

        // Ascend until we find a Device Characteristics dictionary.
        while entry != 0 {
            defer { IOObjectRelease(entry) }
            if let characteristics = IORegistryEntryCreateCFProperty(
                entry, "Device Characteristics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] {
                return DriveIdentity(
                    vendor: (characteristics["Vendor Name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                    product: (characteristics["Product Name"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                    revision: (characteristics["Product Revision Level"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                )
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return nil
            }
            entry = parent
        }
        return nil
    }
}
