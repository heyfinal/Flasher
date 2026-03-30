import Foundation

enum WriteMethod: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case raw = "Raw (DD)"
    case fileCopy = "File Copy (ISO)"
    case asr = "ASR Restore (DMG)"

    var id: String { rawValue }

    var displayName: String {
        rawValue
    }
}

struct WriteOptions {
    var partitionScheme: PartitionScheme
    var filesystem: FileSystem
    var bootMode: BootMode
    var volumeName: String
    var formatBeforeWrite: Bool
    var verifyAfterWrite: Bool
    var checkBadBlocks: Bool
    var persistenceEnabled: Bool
    var persistenceSizeGB: Int
    var persistenceMode: PersistenceMode
    var writeMethod: WriteMethod
}

enum PersistenceMode: String, CaseIterable, Identifiable {
    case none = "None"
    case generic = "Generic"
    case kali = "Kali Live"

    var id: String { rawValue }
}

enum WriteStrategy: String {
    case raw
    case fileCopy
    case asr
}

struct WritePlan {
    var strategy: WriteStrategy
    var requiresFormat: Bool
    var requiresUnmount: Bool
    var usesAsr: Bool
    var usesFileCopy: Bool
    var postWriteKaliPersistence: Bool
}
