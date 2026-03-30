import Foundation

/// Errors that can occur during disk operations
enum DiskError: LocalizedError {
    case executionFailed(terminationStatus: Int32, errorOutput: String)
    case decodingFailed(Error)
    case invalidOutput
    case diskNotFound(String)
    case permissionDenied
    case operationCancelled

    var errorDescription: String? {
        switch self {
        case .executionFailed(let status, let output):
            return "Command failed with status \(status): \(output)"
        case .decodingFailed(let error):
            return "Failed to decode output: \(error.localizedDescription)"
        case .invalidOutput:
            return "Invalid output from command"
        case .diskNotFound(let name):
            return "Disk not found: \(name)"
        case .permissionDenied:
            return "Permission denied. Grant Full Disk Access to Flasher (and Terminal if prompted), then retry."
        case .operationCancelled:
            return "Operation was cancelled"
        }
    }
}

/// Manages disk operations using diskutil
@MainActor
class DiskManager: ObservableObject {
    @Published var availableDisks: [DiskInfo] = []
    @Published var isScanning: Bool = false
    @Published var lastError: Error?

    /// List all available disks
    func listDisks() async throws -> [DiskInfo] {
        isScanning = true
        defer { isScanning = false }

        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["list", "-plist"],
            requiresPrivilege: false
        )

        if result.exitCode != 0 {
            let errorString = String(data: result.stderr, encoding: .utf8) ?? "Unknown error"
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: errorString)
        }

        // Parse plist output
        guard let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] else {
            throw DiskError.invalidOutput
        }

        var disks: [DiskInfo] = []

        // Get all disks from the plist
        if let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] {
            for diskDict in allDisks {
                if let info = try? await parseDiskInfo(from: diskDict) {
                    disks.append(info)
                }

                // Parse partitions
                if let partitions = diskDict["Partitions"] as? [[String: Any]] {
                    for partitionDict in partitions {
                        if let info = try? await parseDiskInfo(from: partitionDict) {
                            disks.append(info)
                        }
                    }
                }
            }
        }

        // Filter to only removable whole disks for safety
        let removableDisks = disks.filter { $0.isRemovable && $0.isWholeDisk && $0.isUSBThumbDrive }
        availableDisks = removableDisks
        return removableDisks
    }

    /// Parse disk info from plist dictionary
    private func parseDiskInfo(from dict: [String: Any]) async throws -> DiskInfo? {
        guard let bsdName = dict["DeviceIdentifier"] as? String else {
            return nil
        }

        // Get detailed info for this disk
        let detailedInfo = try? await getDiskInfo(bsdName: bsdName)

        let size = (dict["Size"] as? Int64) ?? (detailedInfo?["Size"] as? Int64 ?? 0)
        let volumeName = dict["VolumeName"] as? String ?? detailedInfo?["VolumeName"] as? String
        let volumeUUID = dict["VolumeUUID"] as? String ?? detailedInfo?["VolumeUUID"] as? String
        let filesystem = dict["Content"] as? String ?? detailedInfo?["FilesystemType"] as? String
        let mountPoint = dict["MountPoint"] as? String ?? detailedInfo?["MountPoint"] as? String

        // Determine if removable (external)
        let isRemovable = (detailedInfo?["Removable"] as? Bool) ?? !(detailedInfo?["Internal"] as? Bool ?? true)
        let isWholeDisk = (dict["Partitions"] as? [[String: Any]]) != nil
        let isInternal = (detailedInfo?["Internal"] as? Bool) ?? true
        let mediaType = detailedInfo?["MediaType"] as? String
        let busProtocol = detailedInfo?["BusProtocol"] as? String ?? detailedInfo?["Protocol"] as? String

        return DiskInfo(
            id: bsdName,
            bsdName: bsdName,
            deviceIdentifier: "/dev/\(bsdName)",
            size: size,
            sizeString: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
            volumeName: volumeName,
            volumeUUID: volumeUUID,
            filesystem: filesystem,
            mountPoint: mountPoint,
            isRemovable: isRemovable,
            isWholeDisk: isWholeDisk,
            isInternal: isInternal,
            mediaType: mediaType,
            busProtocol: busProtocol
        )
    }

    /// Get detailed info for a specific disk
    private func getDiskInfo(bsdName: String) async throws -> [String: Any] {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", bsdName],
            requiresPrivilege: false
        )

        guard result.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] else {
            return [:]
        }

        return plist
    }

    /// Unmount a disk
    func unmountDisk(bsdName: String) async throws {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["unmountDisk", "force", bsdName],
            requiresPrivilege: true
        )

        if result.exitCode != 0 {
            let errorString = String(data: result.stderr, encoding: .utf8) ?? "Unknown error"
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: errorString)
        }
    }

    /// Erase and format a disk
    func eraseDisk(bsdName: String, filesystem: FileSystem, scheme: PartitionScheme, volumeName: String = "UNTITLED") async throws {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: [
                "eraseDisk",
                filesystem.diskutilName,
                volumeName,
                scheme.diskutilName,
                bsdName
            ],
            requiresPrivilege: true
        )

        if result.exitCode != 0 {
            let errorString = String(data: result.stderr, encoding: .utf8) ?? "Unknown error"
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: errorString)
        }
    }

    /// Refresh the disk list
    func refresh() {
        Task {
            do {
                _ = try await listDisks()
            } catch {
                lastError = error
            }
        }
    }
}
