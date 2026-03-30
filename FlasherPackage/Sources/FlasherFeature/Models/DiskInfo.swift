import Foundation

/// Represents a physical disk or volume
struct DiskInfo: Identifiable, Codable, Hashable {
    let id: String
    let bsdName: String
    let deviceIdentifier: String
    let size: Int64
    let sizeString: String
    let volumeName: String?
    let volumeUUID: String?
    let filesystem: String?
    let mountPoint: String?
    let isRemovable: Bool
    let isWholeDisk: Bool
    let isInternal: Bool
    let mediaType: String?
    let busProtocol: String?

    var displayName: String {
        if let name = volumeName, !name.isEmpty {
            return "\(name) (\(bsdName)) - \(sizeString)"
        }
        return "\(bsdName) - \(sizeString)"
    }

    var isSafeToFormat: Bool {
        // Don't allow formatting of internal disks or mounted system volumes
        guard isRemovable else { return false }
        guard !isInternal else { return false }

        // Check if it's a system volume
        if let mount = mountPoint {
            let systemPaths = ["/", "/System", "/Library", "/Applications", "/Users"]
            if systemPaths.contains(mount) {
                return false
            }
        }

        return true
    }

    var isUSBThumbDrive: Bool {
        guard isRemovable else { return false }
        if let protocolName = busProtocol?.lowercased() {
            return protocolName.contains("usb")
        }
        return true
    }
}

/// Partition scheme options
enum PartitionScheme: String, CaseIterable, Identifiable {
    case mbr = "MBR"
    case gpt = "GPT"
    case apm = "APM"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mbr:
            return "MBR (Master Boot Record) - For BIOS/Legacy systems"
        case .gpt:
            return "GPT (GUID Partition Table) - For UEFI systems"
        case .apm:
            return "APM (Apple Partition Map) - For older Macs"
        }
    }

    var diskutilName: String {
        switch self {
        case .mbr: return "MBR"
        case .gpt: return "GPT"
        case .apm: return "APM"
        }
    }
}

/// Filesystem options
enum FileSystem: String, CaseIterable, Identifiable {
    case fat32 = "FAT32"
    case exfat = "ExFAT"
    case ntfs = "NTFS"
    case apfs = "APFS"
    case hfsPlus = "HFS+"
    case ext4 = "ext4"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fat32:
            return "FAT32 - Most compatible, 4GB file limit"
        case .exfat:
            return "exFAT - Modern, no file size limit"
        case .ntfs:
            return "NTFS - Windows native"
        case .apfs:
            return "APFS - macOS native"
        case .hfsPlus:
            return "HFS+ - Legacy macOS"
        case .ext4:
            return "ext4 - Linux native"
        }
    }

    var diskutilName: String {
        switch self {
        case .fat32: return "MS-DOS FAT32"
        case .exfat: return "ExFAT"
        case .ntfs: return "NTFS"
        case .apfs: return "APFS"
        case .hfsPlus: return "Journaled HFS+"
        case .ext4: return "ext4" // Note: macOS doesn't natively support ext4
        }
    }

    var isSupportedByDiskutil: Bool {
        switch self {
        case .fat32, .exfat, .apfs, .hfsPlus:
            return true
        case .ntfs, .ext4:
            return false
        }
    }
}

/// Boot mode options
enum BootMode: String, CaseIterable, Identifiable {
    case bios = "BIOS"
    case uefi = "UEFI"
    case hybrid = "Hybrid"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bios:
            return "BIOS/Legacy - For older computers"
        case .uefi:
            return "UEFI - For modern computers"
        case .hybrid:
            return "Hybrid - Compatible with both"
        }
    }
}
