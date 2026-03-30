import Foundation
import Darwin

/// Manages writing disk images to USB drives
@MainActor
class WriterManager: ObservableObject {
    @Published var isWriting: Bool = false
    @Published var progress: OperationProgress?
    @Published var lastError: Error?
    @Published var lastCommandOutput: String?

    private var currentProcess: Process?
    private var progressTimer: Timer?
    private var lastProgressSample: (bytes: Int64, time: TimeInterval)?
    private var progressFileHandle: FileHandle?
    private var writeErrorBuffer: String = ""
    private var lastWarning: String?

    /// Write an image to a disk with the provided options
    func writeImage(
        imageURL: URL,
        toDisk bsdName: String,
        options: WriteOptions
    ) async throws -> OperationResult {
        guard !isWriting else {
            throw DiskError.executionFailed(terminationStatus: -1, errorOutput: "Write operation already in progress")
        }

        isWriting = true
        defer { isWriting = false }
        lastCommandOutput = nil
        lastWarning = nil

        // Get file size for progress tracking
        let attributes = try FileManager.default.attributesOfItem(atPath: imageURL.path)
        let totalSize = attributes[.size] as? Int64 ?? 0

        progress = OperationProgress(
            id: UUID(),
            status: "Preparing to write...",
            percentage: 0.0,
            bytesProcessed: 0,
            totalBytes: totalSize,
            speed: 0,
            remainingTime: nil
        )

        do {
            let plan = try await planWrite(imageURL: imageURL, options: options)
            print("[Flasher Debug v2] Strategy: \(plan.strategy), requiresFormat: \(plan.requiresFormat), usesAsr: \(plan.usesAsr), usesFileCopy: \(plan.usesFileCopy)")

            if options.checkBadBlocks {
                progress?.status = "Checking disk for errors..."
                try await verifyDisk(bsdName: bsdName)
            }

            // For raw writes, combine format + write into single privileged session
            // This ensures only ONE password prompt for the entire operation
            if plan.strategy == .raw {
                print("[Flasher Debug v2] Taking RAW write path - single privileged session")
                progress?.status = plan.requiresFormat ? "Formatting and writing..." : "Writing image..."
                progress?.isIndeterminate = plan.requiresFormat

                try await performCombinedFormatAndWrite(
                    imageURL: imageURL,
                    bsdName: bsdName,
                    options: options,
                    requiresFormat: plan.requiresFormat,
                    postWriteKaliPersistence: plan.postWriteKaliPersistence
                )
                progress?.isIndeterminate = false
            } else if plan.requiresFormat {
                // For non-raw strategies (file copy, ASR), format first
                print("[Flasher Debug v2] Taking SEPARATE format path (NOT raw) - will cause extra password prompt!")
                progress?.status = "Formatting disk..."
                progress?.isIndeterminate = true
                try await formatDisk(
                    bsdName: bsdName,
                    filesystem: options.filesystem,
                    scheme: options.partitionScheme,
                    volumeName: options.volumeName,
                    persistenceEnabled: options.persistenceEnabled,
                    persistenceSizeGB: options.persistenceSizeGB
                )
                progress?.isIndeterminate = false
                progress?.percentage = max(progress?.percentage ?? 0, 2.0)
            }

            if plan.strategy == .asr {
                progress?.status = "Restoring image with ASR..."
                try await performASRRestore(imageURL: imageURL, toDisk: bsdName)
            } else if plan.strategy == .fileCopy {
                progress?.status = "Mounting image..."
                do {
                    let mountPath = try await mountImage(imageURL: imageURL)
                    defer { detachImage(mountPath: mountPath) }

                    let stagingPath = try await prepareStagingDirectoryIfNeeded(mountPath: mountPath, options: options)
                    defer { if let stagingPath { try? FileManager.default.removeItem(atPath: stagingPath) } }

                    let sourcePath = stagingPath ?? mountPath

                    try await preflightFileCopy(mountPath: sourcePath, options: options)

                    progress?.status = "Copying files..."
                    try await performFileCopy(from: sourcePath, toDisk: bsdName)

                    if options.verifyAfterWrite {
                        progress?.status = "Verifying files..."
                        try await verifyFileCopy(from: sourcePath, toDisk: bsdName)
                    }
                } catch {
                    if options.writeMethod == .auto {
                        progress?.status = "Mount failed, falling back to raw write..."
                        try await performCombinedFormatAndWrite(
                            imageURL: imageURL,
                            bsdName: bsdName,
                            options: options,
                            requiresFormat: false,
                            postWriteKaliPersistence: plan.postWriteKaliPersistence
                        )
                    } else {
                        throw error
                    }
                }
            }
            // Note: .raw strategy is handled above in performCombinedFormatAndWrite

            progress?.status = "Completed successfully"
            progress?.percentage = 100.0

            if let lastWarning {
                return .success(message: "Successfully wrote \(imageURL.lastPathComponent) to \(bsdName).\n\nWarning: \(lastWarning)")
            }
            return .success(message: "Successfully wrote \(imageURL.lastPathComponent) to \(bsdName)")
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == 3587 {
                if let progress, progress.totalBytes > 0, progress.bytesProcessed >= progress.totalBytes {
                    lastWarning = "Verification skipped due to missing Full Disk Access."
                    self.progress?.status = "Completed with warnings"
                    return .success(message: "Successfully wrote \(imageURL.lastPathComponent) to \(bsdName).\n\nWarning: \(lastWarning!)")
                }
            }
            lastError = error
            progress?.status = "Failed: \(error.localizedDescription)"
            return .failure(error: error)
        }
    }

    /// Legacy method for raw writes - kept for potential fallback scenarios
    private func performRawWrite(
        imageURL: URL,
        bsdName: String,
        options: WriteOptions,
        postWriteKaliPersistence: Bool
    ) async throws {
        progress?.status = "Writing image to disk..."
        try await performWrite(imageURL: imageURL, toDisk: bsdName)

        if options.verifyAfterWrite {
            progress?.status = "Verifying written data..."
            do {
                if let warning = try await verifyWrite(imageURL: imageURL, disk: bsdName) {
                    lastWarning = warning
                }
            } catch DiskError.permissionDenied {
                lastWarning = "Verification skipped due to missing Full Disk Access."
            }
        }

        if postWriteKaliPersistence {
            progress?.status = "Creating Kali persistence partition..."
            try await createKaliPersistencePartition(
                bsdName: bsdName,
                sizeGB: options.persistenceSizeGB
            )
        }
    }

    /// Perform format and write in a SINGLE privileged session.
    /// This ensures only ONE password prompt for the entire operation.
    private func performCombinedFormatAndWrite(
        imageURL: URL,
        bsdName: String,
        options: WriteOptions,
        requiresFormat: Bool,
        postWriteKaliPersistence: Bool
    ) async throws {
        let rdiskName = bsdName.replacingOccurrences(of: "disk", with: "rdisk")

        // Build the command chain
        var commands: [(path: String, arguments: [String])] = []

        // 1. Format if required
        if requiresFormat {
            let sanitizedVolume = options.volumeName.isEmpty ? "UNTITLED" : options.volumeName
            if options.persistenceEnabled && options.persistenceSizeGB > 0 && options.persistenceMode != .kali {
                let totalBytes = try await getDiskSize(bsdName: bsdName)
                let totalGB = max(1, Int(totalBytes / 1_000_000_000))
                let persistenceGB = min(options.persistenceSizeGB, totalGB - 1)
                let mainGB = max(1, totalGB - persistenceGB)

                commands.append((
                    path: "/usr/sbin/diskutil",
                    arguments: [
                        "partitionDisk",
                        "/dev/\(bsdName)",
                        options.partitionScheme.diskutilName,
                        options.filesystem.diskutilName,
                        sanitizedVolume,
                        "\(mainGB)g",
                        "ExFAT",
                        "PERSISTENCE",
                        "\(persistenceGB)g"
                    ]
                ))
            } else {
                commands.append((
                    path: "/usr/sbin/diskutil",
                    arguments: [
                        "eraseDisk",
                        options.filesystem.diskutilName,
                        sanitizedVolume,
                        options.partitionScheme.diskutilName,
                        bsdName
                    ]
                ))
            }
        }

        // 2. Unmount (always needed before raw write)
        commands.append((
            path: "/usr/sbin/diskutil",
            arguments: ["unmountDisk", "force", bsdName]
        ))

        // 3. Write with dd
        commands.append((
            path: "/bin/dd",
            arguments: [
                "if=\(imageURL.path)",
                "of=/dev/\(rdiskName)",
                "bs=1m"
            ]
        ))

        // Run all commands in a single privileged session (ONE password prompt)
        progress?.status = requiresFormat ? "Formatting and writing image..." : "Writing image..."
        progress?.isIndeterminate = true

        print("[Flasher Debug v2] performCombinedFormatAndWrite: Running \(commands.count) commands in SINGLE privileged session:")
        for (index, cmd) in commands.enumerated() {
            print("[Flasher Debug v2]   Command \(index + 1): \(cmd.path) \(cmd.arguments.joined(separator: " "))")
        }

        let result = try await CommandRunner.runChained(
            commands: commands,
            requiresPrivilege: true
        )

        progress?.isIndeterminate = false

        if result.exitCode != 0 {
            let errorString = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputString = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errorString?.isEmpty == false ? errorString! : (outputString?.isEmpty == false ? outputString! : "Write failed")
            lastCommandOutput = detail
            if detail.lowercased().contains("operation not permitted") {
                lastCommandOutput = permissionDeniedHint(devicePath: "/dev/\(rdiskName)")
                throw DiskError.permissionDenied
            }
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: detail)
        }

        try await flushDiskWrites()
        progress?.percentage = 90.0

        // Verification (separate step, doesn't need privilege)
        if options.verifyAfterWrite {
            progress?.status = "Verifying written data..."
            do {
                if let warning = try await verifyWrite(imageURL: imageURL, disk: bsdName) {
                    lastWarning = warning
                }
            } catch DiskError.permissionDenied {
                lastWarning = "Verification skipped due to missing Full Disk Access."
            }
        }

        // Kali persistence (needs separate privilege if required)
        if postWriteKaliPersistence {
            progress?.status = "Creating Kali persistence partition..."
            try await createKaliPersistencePartition(
                bsdName: bsdName,
                sizeGB: options.persistenceSizeGB
            )
        }

        progress?.percentage = 100.0
    }

    /// Unmount disk before writing
    private func unmountDisk(bsdName: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmountDisk", "force", bsdName]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try await process.runAndWait()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Failed to unmount disk"
            lastCommandOutput = errorString
            throw DiskError.executionFailed(terminationStatus: process.terminationStatus, errorOutput: errorString)
        }
    }

    /// Perform the actual write using dd
    private func performWrite(imageURL: URL, toDisk bsdName: String) async throws {
        if !canWriteToDevice(bsdName: bsdName) {
            try await performPrivilegedWrite(imageURL: imageURL, toDisk: bsdName)
            return
        }

        // Unmount the disk before writing (non-privileged path)
        try await unmountDisk(bsdName: bsdName)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        writeErrorBuffer = ""

        // Use rdisk for faster writes
        let rdiskName = bsdName.replacingOccurrences(of: "disk", with: "rdisk")

        process.arguments = [
            "if=\(imageURL.path)",
            "of=/dev/\(rdiskName)",
            "bs=1m"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        currentProcess = process

        // Start monitoring progress
        startProgressMonitoring(errorPipe: errorPipe, process: process)

        try await process.runAndWait()

        stopProgressMonitoring()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (errorString?.isEmpty == false ? errorString! : writeErrorBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            let finalMessage = detail.isEmpty ? "Write failed" : detail
            lastCommandOutput = finalMessage
            if finalMessage.lowercased().contains("operation not permitted") {
                currentProcess = nil
                try await performPrivilegedWrite(imageURL: imageURL, toDisk: bsdName)
                return
            }
            throw DiskError.executionFailed(terminationStatus: process.terminationStatus, errorOutput: finalMessage)
        }

        try await flushDiskWrites()

        currentProcess = nil
    }

    /// Start monitoring dd progress
    private func startProgressMonitoring(errorPipe: Pipe, process: Process) {
        let fileHandle = errorPipe.fileHandleForReading
        progressFileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.appendWriteErrorBuffer(output)
                self?.parseProgressOutput(output)
            }
        }

        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if process.isRunning {
                kill(process.processIdentifier, SIGINFO)
            }
        }
    }

    /// Stop progress monitoring
    private func stopProgressMonitoring() {
        progressTimer?.invalidate()
        progressTimer = nil
        lastProgressSample = nil
        progressFileHandle?.readabilityHandler = nil
        progressFileHandle = nil
    }

    private func appendWriteErrorBuffer(_ output: String) {
        if writeErrorBuffer.count > 8192 {
            writeErrorBuffer = String(writeErrorBuffer.suffix(4096))
        }
        writeErrorBuffer.append(output)
    }

    private func canWriteToDevice(bsdName: String) -> Bool {
        let rdiskName = bsdName.replacingOccurrences(of: "disk", with: "rdisk")
        let devicePath = "/dev/\(rdiskName)"
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: devicePath))
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    private func performPrivilegedWrite(imageURL: URL, toDisk bsdName: String) async throws {
        let rdiskName = bsdName.replacingOccurrences(of: "disk", with: "rdisk")
        let devicePath = "/dev/\(rdiskName)"

        // First, unmount the disk (this typically doesn't require special privileges)
        progress?.status = "Unmounting disk..."
        let unmountResult = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["unmountDisk", "force", bsdName],
            requiresPrivilege: false
        )

        if unmountResult.exitCode != 0 {
            // Try with privilege if unprivileged unmount failed
            let privilegedUnmount = try await CommandRunner.run(
                path: "/usr/sbin/diskutil",
                arguments: ["unmountDisk", "force", bsdName],
                requiresPrivilege: true
            )
            if privilegedUnmount.exitCode != 0 {
                let errorString = String(data: privilegedUnmount.stderr, encoding: .utf8) ?? "Failed to unmount disk"
                throw DiskError.executionFailed(terminationStatus: privilegedUnmount.exitCode, errorOutput: errorString)
            }
        }

        progress?.status = "Writing image to disk..."
        progress?.isIndeterminate = false

        // Use Apple's authopen for proper privileged disk access
        // This shows a native system authorization dialog
        do {
            try await AuthOpenHelper.writeToDeviceSimple(
                sourceURL: imageURL,
                devicePath: devicePath
            ) { @Sendable bytesWritten, total in
                Task { @MainActor [weak self] in
                    guard let self = self, var currentProgress = self.progress else { return }
                    let percentage = total > 0 ? Double(bytesWritten) / Double(total) * 100.0 : 0
                    let now = Date().timeIntervalSince1970
                    let speed = self.calculateSpeed(bytes: bytesWritten, now: now)
                    currentProgress.bytesProcessed = bytesWritten
                    currentProgress.totalBytes = total
                    currentProgress.percentage = min(percentage, 99.0)
                    currentProgress.status = "Writing..."
                    currentProgress.speed = speed
                    currentProgress.remainingTime = self.calculateRemainingTime(
                        bytesProcessed: bytesWritten,
                        totalBytes: total,
                        speed: speed
                    )
                    self.progress = currentProgress
                }
            }
        } catch let error as AuthOpenHelper.AuthOpenError {
            lastCommandOutput = error.localizedDescription
            switch error {
            case .authorizationDenied:
                throw DiskError.permissionDenied
            case .authopenFailed(let msg) where msg.lowercased().contains("operation not permitted"):
                lastCommandOutput = permissionDeniedHint(devicePath: devicePath)
                throw DiskError.permissionDenied
            default:
                throw DiskError.executionFailed(terminationStatus: -1, errorOutput: error.localizedDescription)
            }
        }

        try await flushDiskWrites()
    }

    /// Fallback method using osascript + dd if authopen fails
    private func performPrivilegedWriteFallback(imageURL: URL, toDisk bsdName: String) async throws {
        progress?.isIndeterminate = true
        defer { progress?.isIndeterminate = false }

        let stagedURL = try stageImageForPrivilegedWrite(imageURL: imageURL)
        defer { try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent()) }

        let rdiskName = bsdName.replacingOccurrences(of: "disk", with: "rdisk")

        // Run unmount and dd together in a single privileged session
        let result = try await CommandRunner.runChained(
            commands: [
                ("/usr/sbin/diskutil", ["unmountDisk", "force", bsdName]),
                ("/bin/dd", ["if=\(stagedURL.path)", "of=/dev/\(rdiskName)", "bs=1m"])
            ],
            requiresPrivilege: true
        )

        if result.exitCode != 0 {
            let errorString = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputString = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errorString?.isEmpty == false ? errorString! : (outputString?.isEmpty == false ? outputString! : "Write failed")
            lastCommandOutput = detail
            if detail.lowercased().contains("operation not permitted") {
                lastCommandOutput = permissionDeniedHint(devicePath: "/dev/\(rdiskName)")
                throw DiskError.permissionDenied
            }
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: detail)
        }

        try await flushDiskWrites()
    }

    private func stageImageForPrivilegedWrite(imageURL: URL) throws -> URL {
        let stagingDir = URL(fileURLWithPath: "/tmp").appendingPathComponent("FlasherStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedURL = stagingDir.appendingPathComponent(imageURL.lastPathComponent)
        try FileManager.default.copyItem(at: imageURL, to: stagedURL)
        return stagedURL
    }

    private func permissionDeniedHint(devicePath: String) -> String {
        "Permission denied writing to \(devicePath). Grant Full Disk Access to Flasher (and Terminal if prompted), then retry."
    }

    /// Parse dd progress output
    private func parseProgressOutput(_ output: String) {
        guard let parsed = Self.parseDDProgress(output: output) else { return }
        guard let progress = progress else { return }

        let bytes = parsed.bytes
        let now = Date().timeIntervalSince1970
        let speed = parsed.speed ?? calculateSpeed(bytes: bytes, now: now)
        let percentage: Double
        if progress.totalBytes > 0 {
            percentage = Double(bytes) / Double(progress.totalBytes) * 100.0
        } else {
            percentage = 0.0
        }

        self.progress = OperationProgress(
            id: progress.id,
            status: "Writing...",
            percentage: min(percentage, 99.0), // Don't show 100% until verify completes
            bytesProcessed: bytes,
            totalBytes: progress.totalBytes,
            speed: speed,
            remainingTime: calculateRemainingTime(bytesProcessed: bytes, totalBytes: progress.totalBytes, speed: speed)
        )
    }

    /// Calculate write speed
    private func calculateSpeed(bytes: Int64, now: TimeInterval) -> Double {
        defer { lastProgressSample = (bytes, now) }
        guard let last = lastProgressSample else {
            return 0
        }
        let deltaBytes = bytes - last.bytes
        let deltaTime = now - last.time
        guard deltaTime > 0 else { return 0 }
        return Double(deltaBytes) / deltaTime
    }

    /// Calculate remaining time
    private func calculateRemainingTime(bytesProcessed: Int64, totalBytes: Int64, speed: Double) -> TimeInterval? {
        guard speed > 0 else { return nil }
        let remaining = totalBytes - bytesProcessed
        return Double(remaining) / speed
    }

    static func parseDDProgress(output: String) -> (bytes: Int64, speed: Double?)? {
        let sanitized = output.replacingOccurrences(of: "\n", with: " ")

        let primaryBytesRegex = try? NSRegularExpression(pattern: #"(\d+)\s+bytes\s+(?:transferred|copied)"#, options: .caseInsensitive)
        let fallbackBytesRegex = try? NSRegularExpression(pattern: #"(\d+)\s+bytes"#, options: .caseInsensitive)

        let bytes: Int64
        if let bytesMatch = primaryBytesRegex?.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized)).last,
           let bytesRange = Range(bytesMatch.range(at: 1), in: sanitized),
           let parsed = Int64(sanitized[bytesRange]) {
            bytes = parsed
        } else if let bytesMatch = fallbackBytesRegex?.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized)).first,
                  let bytesRange = Range(bytesMatch.range(at: 1), in: sanitized),
                  let parsed = Int64(sanitized[bytesRange]) {
            bytes = parsed
        } else {
            return nil
        }

        let bytesPerSecRegex = try? NSRegularExpression(pattern: #"\((\d+)\s+bytes/sec\)"#, options: .caseInsensitive)
        if let speedMatch = bytesPerSecRegex?.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized)).last,
           let speedRange = Range(speedMatch.range(at: 1), in: sanitized),
           let speedValue = Double(sanitized[speedRange]) {
            return (bytes: bytes, speed: speedValue)
        }

        let unitSpeedRegex = try? NSRegularExpression(pattern: #",\s*([\d\.]+)\s*([kMG]?B)/s"#, options: .caseInsensitive)
        if let speedMatch = unitSpeedRegex?.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized)).last,
           let valueRange = Range(speedMatch.range(at: 1), in: sanitized),
           let unitRange = Range(speedMatch.range(at: 2), in: sanitized),
           let value = Double(sanitized[valueRange]) {
            let unit = String(sanitized[unitRange]).uppercased()
            let multiplier: Double
            switch unit {
            case "KB":
                multiplier = 1_024
            case "MB":
                multiplier = 1_024 * 1_024
            case "GB":
                multiplier = 1_024 * 1_024 * 1_024
            default:
                multiplier = 1
            }
            return (bytes: bytes, speed: value * multiplier)
        }

        return (bytes: bytes, speed: nil)
    }

    /// Verify written data
    private func verifyWrite(imageURL: URL, disk: String) async throws -> String? {
        // First check if FDA is actually enabled
        let hasFDA = FullDiskAccessChecker.hasFullDiskAccess()

        // Prefer mount-based verification to avoid raw device access.
        do {
            let imageMountPath = try await mountImage(imageURL: imageURL)
            defer { detachImage(mountPath: imageMountPath) }

            // Try to mount the written disk
            do {
                try await mountDiskIfNeeded(bsdName: disk)
            } catch {
                // Raw write may have changed the partition table, disk may not be mountable
                // This is expected for many Linux ISOs
                return "Verification skipped - disk format may not be mountable on macOS (this is normal for Linux ISOs)."
            }

            let mountPoints = try await getDiskMountPoints(bsdName: disk)
            guard let targetMount = mountPoints.first else {
                return "Verification skipped - target disk has no mountable partitions (this is normal for raw writes)."
            }

            try await verifyMountedCopy(from: imageMountPath, to: targetMount)
            progress?.status = "Verification completed"
            return nil
        } catch {
            let nsError = error as NSError

            // Check for TCC/permission errors
            if nsError.domain == NSCocoaErrorDomain, nsError.code == 3587 {
                if !hasFDA {
                    throw DiskError.permissionDenied
                }
                // FDA is enabled but still got permission error - likely file location issue
                return "Verification skipped - source file may be in a restricted location."
            }

            if case DiskError.executionFailed(let status, let output) = error,
               status != 0,
               (output.lowercased().contains("mount") || output.lowercased().contains("not found")) {
                return "Verification skipped - image or disk could not be mounted."
            }

            throw error
        }
    }

    private func planWrite(imageURL: URL, options: WriteOptions) async throws -> WritePlan {
        let isKali = await isKaliLiveISO(imageURL: imageURL)
        let strategy: WriteStrategy
        switch options.writeMethod {
        case .raw:
            strategy = .raw
        case .fileCopy:
            strategy = .fileCopy
        case .asr:
            strategy = .asr
        case .auto:
            let ext = imageURL.pathExtension.lowercased()
            if ext == "dmg" {
                strategy = .asr
            } else {
                // ISOs and other image formats use raw write by default
                // This is the most reliable method for Linux ISOs and ensures
                // a single privileged session for format + write
                strategy = .raw
            }
        }

        let useKaliPersistence = options.persistenceEnabled && options.persistenceMode == .kali && isKali
        let adjustedStrategy: WriteStrategy
        if useKaliPersistence {
            adjustedStrategy = .raw
        } else {
            adjustedStrategy = strategy
        }

        let requiresFormat: Bool
        if adjustedStrategy == .fileCopy {
            requiresFormat = true
        } else {
            requiresFormat = options.formatBeforeWrite || (options.persistenceEnabled && options.persistenceMode != .kali)
        }

        return WritePlan(
            strategy: adjustedStrategy,
            requiresFormat: requiresFormat,
            requiresUnmount: adjustedStrategy == .raw,
            usesAsr: adjustedStrategy == .asr,
            usesFileCopy: adjustedStrategy == .fileCopy,
            postWriteKaliPersistence: useKaliPersistence
        )
    }

    private func verifyDisk(bsdName: String) async throws {
        do {
            let result = try await CommandRunner.run(
                path: "/usr/sbin/diskutil",
                arguments: ["verifyVolume", bsdName],
                requiresPrivilege: true
            )
            if result.exitCode != 0 {
                throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: "Disk verification failed")
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == 3587 {
                throw DiskError.permissionDenied
            }
            throw error
        }
    }

    private func formatDisk(
        bsdName: String,
        filesystem: FileSystem,
        scheme: PartitionScheme,
        volumeName: String,
        persistenceEnabled: Bool,
        persistenceSizeGB: Int
    ) async throws {
        guard filesystem.isSupportedByDiskutil else {
            throw DiskError.executionFailed(terminationStatus: -1, errorOutput: "Selected file system isn't supported on macOS.")
        }
        let sanitizedVolume = volumeName.isEmpty ? "UNTITLED" : volumeName
        if persistenceEnabled && persistenceSizeGB > 0 {
            let totalBytes = try await getDiskSize(bsdName: bsdName)
            let totalGB = max(1, Int(totalBytes / 1_000_000_000))
            let persistenceGB = min(persistenceSizeGB, totalGB - 1)
            let mainGB = max(1, totalGB - persistenceGB)

            let result = try await CommandRunner.run(
                path: "/usr/sbin/diskutil",
                arguments: [
                    "partitionDisk",
                    "/dev/\(bsdName)",
                    scheme.diskutilName,
                    filesystem.diskutilName,
                    sanitizedVolume,
                    "\(mainGB)g",
                    "ExFAT",
                    "PERSISTENCE",
                    "\(persistenceGB)g"
                ],
                requiresPrivilege: true
            )
            if result.exitCode != 0 {
                let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderr?.isEmpty == false ? stderr! : (stdout?.isEmpty == false ? stdout! : "Partitioning failed")
                lastCommandOutput = detail
                throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: detail)
            }
        } else {
            let result = try await CommandRunner.run(
                path: "/usr/sbin/diskutil",
                arguments: [
                    "eraseDisk",
                    filesystem.diskutilName,
                    sanitizedVolume,
                    scheme.diskutilName,
                    bsdName
                ],
                requiresPrivilege: true
            )
            if result.exitCode != 0 {
                let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderr?.isEmpty == false ? stderr! : (stdout?.isEmpty == false ? stdout! : "Format failed")
                lastCommandOutput = detail
                throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: detail)
            }
        }
    }

    private func performASRRestore(imageURL: URL, toDisk bsdName: String) async throws {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/asr",
            arguments: [
                "restore",
                "--source",
                imageURL.path,
                "--target",
                "/dev/\(bsdName)",
                "--erase",
                "--noprompt"
            ],
            requiresPrivilege: true
        )
        if result.exitCode != 0 {
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: "ASR restore failed")
        }
    }

    private func mountImage(imageURL: URL) async throws -> String {
        let mountPath = "/tmp/FlasherMount-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: mountPath, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach",
            imageURL.path,
            "-nobrowse",
            "-readonly",
            "-noverify",
            "-mountpoint",
            mountPath
        ]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try await process.runAndWait()
        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errorString?.isEmpty == false ? errorString! : (outputString?.isEmpty == false ? outputString! : "Failed to mount image")
            try? FileManager.default.removeItem(atPath: mountPath)
            throw DiskError.executionFailed(terminationStatus: process.terminationStatus, errorOutput: detail)
        }
        return mountPath
    }

    private func detachImage(mountPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPath, "-force"]
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(atPath: mountPath)
    }

    private func preflightFileCopy(mountPath: String, options: WriteOptions) async throws {
        let installWimPath = URL(fileURLWithPath: mountPath).appendingPathComponent("sources/install.wim").path
        if FileManager.default.fileExists(atPath: installWimPath) && options.filesystem == .fat32 {
            let attrs = try FileManager.default.attributesOfItem(atPath: installWimPath)
            let size = attrs[.size] as? Int64 ?? 0
            if size > 4_000_000_000 {
                throw DiskError.executionFailed(
                    terminationStatus: -1,
                    errorOutput: "Windows ISO has install.wim > 4GB and requires splitting. Enable FAT32 with WIM split or use exFAT/raw."
                )
            }
        }
    }

    private func performFileCopy(from mountPath: String, toDisk bsdName: String) async throws {
        guard let destination = try await getDiskMountPoint(bsdName: bsdName) else {
            throw DiskError.diskNotFound(bsdName)
        }

        if let totalBytes = try? await calculateDirectorySize(path: mountPath), totalBytes > 0 {
            if var current = progress {
                current.totalBytes = totalBytes
                self.progress = current
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = [
            "-a",
            "--info=progress2",
            "\(mountPath)/",
            "\(destination)/"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        currentProcess = process
        startRsyncProgressMonitoring(outputPipe: outputPipe)

        try await process.runAndWait()

        stopProgressMonitoring()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "File copy failed"
            throw DiskError.executionFailed(terminationStatus: process.terminationStatus, errorOutput: errorString)
        }
    }

    private func verifyFileCopy(from mountPath: String, toDisk bsdName: String) async throws {
        guard let destination = try await getDiskMountPoint(bsdName: bsdName) else {
            throw DiskError.diskNotFound(bsdName)
        }
        try await verifyMountedCopy(from: mountPath, to: destination)
    }

    private func getDiskMountPoint(bsdName: String) async throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", bsdName]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try await process.runAndWait()

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: outputPipe.fileHandleForReading.readDataToEndOfFile(), format: nil) as? [String: Any] else {
            return nil
        }
        return plist["MountPoint"] as? String
    }

    private func getDiskMountPoints(bsdName: String) async throws -> [String] {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["list", "-plist"],
            requiresPrivilege: false
        )

        guard result.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        for diskDict in allDisks {
            guard let diskId = diskDict["DeviceIdentifier"] as? String, diskId == bsdName else { continue }
            var mounts: [String] = []
            if let partitions = diskDict["Partitions"] as? [[String: Any]] {
                for part in partitions {
                    if let mount = part["MountPoint"] as? String {
                        mounts.append(mount)
                    }
                }
            } else if let mount = diskDict["MountPoint"] as? String {
                mounts.append(mount)
            }
            return mounts
        }
        return []
    }

    private func mountDiskIfNeeded(bsdName: String) async throws {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["mountDisk", bsdName],
            requiresPrivilege: false
        )
        if result.exitCode != 0 {
            let errorString = String(data: result.stderr, encoding: .utf8) ?? "Failed to mount disk"
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: errorString)
        }
    }

    private func verifyMountedCopy(from sourcePath: String, to destinationPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = [
            "-a",
            "--checksum",
            "--dry-run",
            "\(sourcePath)/",
            "\(destinationPath)/"
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try await process.runAndWait()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 || !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DiskError.executionFailed(terminationStatus: process.terminationStatus, errorOutput: "Verification failed")
        }
    }

    private func getDiskSize(bsdName: String) async throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", bsdName]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        try await process.runAndWait()

        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: outputPipe.fileHandleForReading.readDataToEndOfFile(), format: nil) as? [String: Any],
              let size = plist["Size"] as? Int64 else {
            return 0
        }

        return size
    }

    private func startRsyncProgressMonitoring(outputPipe: Pipe) {
        let fileHandle = outputPipe.fileHandleForReading
        progressFileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.parseRsyncProgress(output)
            }
        }
    }

    private func parseRsyncProgress(_ output: String) {
        guard let progress = progress else { return }
        let sanitized = output.replacingOccurrences(of: "\n", with: " ")
        let regex = try? NSRegularExpression(pattern: #"^\s*([\d,]+)\s+(\d+)%\s+([\d\.]+)([kMG]?B)/s"#, options: .anchorsMatchLines)
        guard let match = regex?.matches(in: sanitized, range: NSRange(sanitized.startIndex..., in: sanitized)).last else {
            return
        }

        guard let bytesRange = Range(match.range(at: 1), in: sanitized),
              let percentRange = Range(match.range(at: 2), in: sanitized),
              let speedValueRange = Range(match.range(at: 3), in: sanitized),
              let speedUnitRange = Range(match.range(at: 4), in: sanitized) else {
            return
        }

        let bytesString = sanitized[bytesRange].replacingOccurrences(of: ",", with: "")
        let bytes = Int64(bytesString) ?? 0
        let percent = Double(sanitized[percentRange]) ?? 0
        let speedValue = Double(sanitized[speedValueRange]) ?? 0
        let unit = sanitized[speedUnitRange].uppercased()

        let multiplier: Double
        switch unit {
        case "KB":
            multiplier = 1_024
        case "MB":
            multiplier = 1_024 * 1_024
        case "GB":
            multiplier = 1_024 * 1_024 * 1_024
        default:
            multiplier = 1
        }

        let speed = speedValue * multiplier

        self.progress = OperationProgress(
            id: progress.id,
            status: "Copying files...",
            percentage: min(percent, 99.0),
            bytesProcessed: bytes,
            totalBytes: progress.totalBytes,
            speed: speed,
            remainingTime: nil
        )
    }

    private func calculateDirectorySize(path: String) async throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try await process.runAndWait()
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let components = output.split(separator: "\t")
        guard let kbString = components.first, let kb = Int64(kbString) else { return 0 }
        return kb * 1024
    }

    private func prepareStagingDirectoryIfNeeded(mountPath: String, options: WriteOptions) async throws -> String? {
        guard options.filesystem == .fat32 else { return nil }
        let installWimPath = URL(fileURLWithPath: mountPath).appendingPathComponent("sources/install.wim").path
        guard FileManager.default.fileExists(atPath: installWimPath) else { return nil }

        let attrs = try FileManager.default.attributesOfItem(atPath: installWimPath)
        let size = attrs[.size] as? Int64 ?? 0
        guard size > 4_000_000_000 else { return nil }

        guard let wimlibPath = resolveWimlibPath() else {
            throw DiskError.executionFailed(terminationStatus: -1, errorOutput: "wimlib-imagex not found. Install wimlib to split large WIM files.")
        }

        let stagingPath = "/tmp/FlasherStaging-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: stagingPath, withIntermediateDirectories: true)

        let copyProcess = Process()
        copyProcess.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        copyProcess.arguments = ["-a", "\(mountPath)/", "\(stagingPath)/"]
        try await copyProcess.runAndWait()
        if copyProcess.terminationStatus != 0 {
            throw DiskError.executionFailed(terminationStatus: copyProcess.terminationStatus, errorOutput: "Failed to stage ISO contents")
        }

        let sourcesPath = URL(fileURLWithPath: stagingPath).appendingPathComponent("sources")
        let installWimStaged = sourcesPath.appendingPathComponent("install.wim").path
        let installSwmPattern = sourcesPath.appendingPathComponent("install.swm").path

        let splitProcess = Process()
        splitProcess.executableURL = URL(fileURLWithPath: wimlibPath)
        splitProcess.arguments = [
            "split",
            installWimStaged,
            installSwmPattern,
            "4000"
        ]
        try await splitProcess.runAndWait()
        if splitProcess.terminationStatus != 0 {
            throw DiskError.executionFailed(terminationStatus: splitProcess.terminationStatus, errorOutput: "Failed to split install.wim")
        }

        try FileManager.default.removeItem(atPath: installWimStaged)
        return stagingPath
    }

    private func resolveWimlibPath() -> String? {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/wimlib-imagex",
            "/opt/homebrew/bin/wimlib-imagex",
            "\(homePath)/workapps/Flasher/tools/wimlib/dist/bin/wimlib-imagex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func isKaliLiveISO(imageURL: URL) async -> Bool {
        guard imageURL.pathExtension.lowercased() == "iso" else { return false }
        do {
            let mountPath = try await mountImage(imageURL: imageURL)
            defer { detachImage(mountPath: mountPath) }

            let infoPath = URL(fileURLWithPath: mountPath).appendingPathComponent(".disk/info").path
            let livePath = URL(fileURLWithPath: mountPath).appendingPathComponent("live").path
            let info = try? String(contentsOfFile: infoPath, encoding: .utf8)
            if let info, info.lowercased().contains("kali") {
                return true
            }
            return FileManager.default.fileExists(atPath: livePath)
        } catch {
            return false
        }
    }

    private func createKaliPersistencePartition(bsdName: String, sizeGB: Int) async throws {
        let mkfsPath = resolveMkfsExt4Path()
        guard let mkfsPath else {
            throw DiskError.executionFailed(
                terminationStatus: -1,
                errorOutput: "mkfs.ext4 not found. Install e2fsprogs to create Kali persistence."
            )
        }

        let slice = try await ensurePersistenceSlice(bsdName: bsdName, sizeGB: sizeGB)
        let rdiskSlice = slice.replacingOccurrences(of: "disk", with: "rdisk")

        let stagingPath = "/tmp/FlasherKaliPersistence-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: stagingPath, withIntermediateDirectories: true)
        let confPath = URL(fileURLWithPath: stagingPath).appendingPathComponent("persistence.conf")
        try "/ union\n".write(to: confPath, atomically: true, encoding: .utf8)

        let result = try await CommandRunner.run(
            path: mkfsPath,
            arguments: [
                "-L",
                "persistence",
                "-d",
                stagingPath,
                "/dev/\(rdiskSlice)"
            ],
            requiresPrivilege: true
        )
        if result.exitCode != 0 {
            let errorString = String(data: result.stderr, encoding: .utf8) ?? "mkfs.ext4 failed"
            throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: errorString)
        }

        try? FileManager.default.removeItem(atPath: stagingPath)
    }

    private func ensurePersistenceSlice(bsdName: String, sizeGB: Int) async throws -> String {
        if let freeSlice = try await findFreeSpaceSlice(bsdName: bsdName) {
            let result = try await CommandRunner.run(
                path: "/usr/sbin/diskutil",
                arguments: [
                    "eraseVolume",
                    "MS-DOS",
                    "PERSISTENCE",
                    "/dev/\(freeSlice)"
                ],
                requiresPrivilege: true
            )
            if result.exitCode != 0 {
                let errorString = String(data: result.stderr, encoding: .utf8) ?? "Failed to create persistence partition"
                throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: errorString)
            }
        } else {
            let result = try await CommandRunner.run(
                path: "/usr/sbin/diskutil",
                arguments: [
                    "addPartition",
                    "/dev/\(bsdName)",
                    "MS-DOS",
                    "PERSISTENCE",
                    "\(sizeGB)g"
                ],
                requiresPrivilege: true
            )
            if result.exitCode != 0 {
                let errorString = String(data: result.stderr, encoding: .utf8) ?? "Failed to add persistence partition"
                throw DiskError.executionFailed(terminationStatus: result.exitCode, errorOutput: errorString)
            }
        }

        if let slice = try await findPartitionByName(bsdName: bsdName, name: "PERSISTENCE") {
            return slice
        }
        throw DiskError.diskNotFound("PERSISTENCE")
    }

    private func findFreeSpaceSlice(bsdName: String) async throws -> String? {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["list", "-plist"],
            requiresPrivilege: false
        )
        guard result.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return nil
        }
        for disk in allDisks {
            if disk["DeviceIdentifier"] as? String != bsdName { continue }
            if let partitions = disk["Partitions"] as? [[String: Any]] {
                for part in partitions {
                    let content = (part["Content"] as? String ?? "").lowercased()
                    let name = (part["VolumeName"] as? String ?? "").lowercased()
                    if content.contains("free") || name.contains("free") {
                        return part["DeviceIdentifier"] as? String
                    }
                }
            }
        }
        return nil
    }

    private func findPartitionByName(bsdName: String, name: String) async throws -> String? {
        let result = try await CommandRunner.run(
            path: "/usr/sbin/diskutil",
            arguments: ["list", "-plist"],
            requiresPrivilege: false
        )
        guard result.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return nil
        }
        for disk in allDisks {
            if disk["DeviceIdentifier"] as? String != bsdName { continue }
            if let partitions = disk["Partitions"] as? [[String: Any]] {
                for part in partitions {
                    if let volumeName = part["VolumeName"] as? String,
                       volumeName.caseInsensitiveCompare(name) == .orderedSame {
                        return part["DeviceIdentifier"] as? String
                    }
                }
            }
        }
        return nil
    }

    private func resolveMkfsExt4Path() -> String? {
        let candidates = [
            "/usr/local/sbin/mkfs.ext4",
            "/opt/homebrew/sbin/mkfs.ext4",
            "/usr/sbin/mkfs.ext4"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func flushDiskWrites() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sync")
        try await process.runAndWait()
    }

    /// Cancel the current write operation
    func cancelWrite() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            currentProcess = nil
            isWriting = false
            progress?.status = "Cancelled"
        }
    }
}
