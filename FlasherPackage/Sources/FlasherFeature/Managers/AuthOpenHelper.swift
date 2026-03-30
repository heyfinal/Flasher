import Foundation
import Security

/// Helper for privileged file operations using macOS authopen.
/// This is Apple's recommended approach for privileged disk access.
/// See: man authopen, https://developer.apple.com/library/archive/documentation/Security/Conceptual/authorization_concepts/
enum AuthOpenHelper {

    enum AuthOpenError: Error, LocalizedError {
        case authorizationFailed(OSStatus)
        case authorizationDenied
        case externalFormFailed
        case authopenFailed(String)
        case fileDescriptorNotReceived
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .authorizationFailed(let status):
                return "Authorization failed with status: \(status)"
            case .authorizationDenied:
                return "Authorization denied by user"
            case .externalFormFailed:
                return "Failed to create external authorization form"
            case .authopenFailed(let message):
                return "authopen failed: \(message)"
            case .fileDescriptorNotReceived:
                return "Failed to receive file descriptor from authopen"
            case .writeFailed(let message):
                return "Write operation failed: \(message)"
            }
        }
    }

    /// Write data to a device file using authopen for privilege escalation.
    /// This uses Apple's official Authorization Services mechanism.
    ///
    /// - Parameters:
    ///   - sourceURL: URL of the source file to write
    ///   - devicePath: Path to the device (e.g., /dev/rdisk2)
    ///   - progressHandler: Optional callback for progress updates
    /// - Returns: True if successful
    static func writeToDevice(
        sourceURL: URL,
        devicePath: String,
        progressHandler: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        // Get source file size
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let totalSize = attributes[.size] as? Int64 ?? 0

        // Create authorization for write access to the device
        let authRef = try createAuthorization(for: devicePath, readWrite: true)
        defer { AuthorizationFree(authRef, []) }

        // Get external form for passing to authopen
        let extForm = try getExternalForm(authRef)

        // Use authopen to get a privileged file descriptor
        let deviceFD = try await runAuthOpen(
            path: devicePath,
            externalForm: extForm,
            flags: O_RDWR
        )
        defer { close(deviceFD) }

        // Open source file
        guard let sourceHandle = FileHandle(forReadingAtPath: sourceURL.path) else {
            throw AuthOpenError.writeFailed("Cannot open source file")
        }
        defer { try? sourceHandle.close() }

        // Write data in chunks
        let bufferSize = 1024 * 1024 // 1MB chunks
        var bytesWritten: Int64 = 0

        while true {
            autoreleasepool {
                let data = sourceHandle.readData(ofLength: bufferSize)
                if data.isEmpty { return }

                data.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    let written = write(deviceFD, baseAddress, data.count)
                    if written > 0 {
                        bytesWritten += Int64(written)
                        progressHandler?(bytesWritten, totalSize)
                    }
                }
            }

            // Check if we've written everything
            if bytesWritten >= totalSize {
                break
            }
        }

        // Sync to ensure all data is written
        fsync(deviceFD)
    }

    /// Create an AuthorizationRef for the specified file operation
    private static func createAuthorization(for path: String, readWrite: Bool) throws -> AuthorizationRef {
        var authRef: AuthorizationRef?

        // Create empty authorization
        var status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let auth = authRef else {
            throw AuthOpenError.authorizationFailed(status)
        }

        // Request the appropriate right for the file
        let rightName = readWrite
            ? "sys.openfile.readwrite.\(path)"
            : "sys.openfile.readonly.\(path)"

        // Use withCString to safely pass the string pointer
        status = rightName.withCString { rightNamePtr in
            var item = AuthorizationItem(
                name: rightNamePtr,
                valueLength: 0,
                value: nil,
                flags: 0
            )

            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)

                // Request authorization with user interaction
                let flags: AuthorizationFlags = [
                    .interactionAllowed,
                    .extendRights,
                    .preAuthorize
                ]

                return AuthorizationCopyRights(auth, &rights, nil, flags, nil)
            }
        }

        if status == errAuthorizationDenied || status == errAuthorizationCanceled {
            AuthorizationFree(auth, [])
            throw AuthOpenError.authorizationDenied
        }

        guard status == errAuthorizationSuccess else {
            AuthorizationFree(auth, [])
            throw AuthOpenError.authorizationFailed(status)
        }

        return auth
    }

    /// Convert AuthorizationRef to external form for passing to authopen
    private static func getExternalForm(_ authRef: AuthorizationRef) throws -> Data {
        var extForm = AuthorizationExternalForm()
        let status = AuthorizationMakeExternalForm(authRef, &extForm)

        guard status == errAuthorizationSuccess else {
            throw AuthOpenError.externalFormFailed
        }

        // Convert to Data
        return withUnsafeBytes(of: &extForm.bytes) { Data($0) }
    }

    /// Run authopen to get a privileged file descriptor
    private static func runAuthOpen(
        path: String,
        externalForm: Data,
        flags: Int32
    ) async throws -> Int32 {
        // Create socket pair for receiving the file descriptor
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw AuthOpenError.authopenFailed("Failed to create socket pair")
        }

        let parentSocket = sockets[0]
        let childSocket = sockets[1]

        defer {
            close(parentSocket)
        }

        // Set up the process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        process.arguments = [
            "-stdoutpipe",
            "-extauth",
            "-o", String(flags),
            path
        ]

        // Set up pipes
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        // Redirect stdout to our socket
        process.standardOutput = FileHandle(fileDescriptor: childSocket, closeOnDealloc: false)

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        // Write the external authorization form to stdin
        stdinPipe.fileHandleForWriting.write(externalForm)
        try stdinPipe.fileHandleForWriting.close()

        // Close child socket in parent
        close(childSocket)

        // Receive the file descriptor via SCM_RIGHTS
        let receivedFD = try receiveFileDescriptor(from: parentSocket)

        try await process.runAndWait()

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw AuthOpenError.authopenFailed(errorString)
        }

        guard receivedFD >= 0 else {
            throw AuthOpenError.fileDescriptorNotReceived
        }

        return receivedFD
    }

    /// Receive a file descriptor via SCM_RIGHTS
    private static func receiveFileDescriptor(from socket: Int32) throws -> Int32 {
        // Allocate control message buffer
        let controlLen = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size
        let controlBuffer = UnsafeMutableRawPointer.allocate(byteCount: controlLen, alignment: MemoryLayout<cmsghdr>.alignment)
        defer { controlBuffer.deallocate() }

        // Allocate buffer for dummy data
        let dataBuffer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { dataBuffer.deallocate() }

        // Set up iovec and msghdr within a single scope to ensure pointers remain valid
        var iov = iovec(iov_base: dataBuffer, iov_len: 1)

        let received: Int = withUnsafeMutablePointer(to: &iov) { iovPtr in
            var msg = msghdr()
            msg.msg_iov = iovPtr
            msg.msg_iovlen = 1
            msg.msg_control = controlBuffer
            msg.msg_controllen = socklen_t(controlLen)

            return recvmsg(socket, &msg, 0)
        }

        guard received >= 0 else {
            throw AuthOpenError.fileDescriptorNotReceived
        }

        // Extract the file descriptor from the control message
        let cmsg = controlBuffer.assumingMemoryBound(to: cmsghdr.self)
        guard cmsg.pointee.cmsg_level == SOL_SOCKET,
              cmsg.pointee.cmsg_type == SCM_RIGHTS else {
            throw AuthOpenError.fileDescriptorNotReceived
        }

        // The file descriptor follows the cmsghdr
        let fdPtr = controlBuffer.advanced(by: MemoryLayout<cmsghdr>.size).assumingMemoryBound(to: Int32.self)
        return fdPtr.pointee
    }
}

// MARK: - Simpler approach using authopen with pipes (fallback)

extension AuthOpenHelper {

    /// Simpler approach: Use authopen to write directly via stdin.
    /// This is less efficient but simpler and doesn't require SCM_RIGHTS handling.
    static func writeToDeviceSimple(
        sourceURL: URL,
        devicePath: String,
        progressHandler: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let totalSize = attributes[.size] as? Int64 ?? 0

        // Use authopen with -w flag to write stdin to the file
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
        process.arguments = ["-w", devicePath]

        // Pipe the source file to authopen's stdin
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        // Write the source file in chunks
        guard let sourceHandle = FileHandle(forReadingAtPath: sourceURL.path) else {
            process.terminate()
            throw AuthOpenError.writeFailed("Cannot open source file")
        }

        let writeHandle = stdinPipe.fileHandleForWriting
        let bufferSize = 1024 * 1024 // 1MB

        // Use actor-isolated counter for thread safety
        let counter = ByteCounter()

        // Write in background to avoid blocking
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var keepReading = true
                while keepReading {
                    autoreleasepool {
                        let data = sourceHandle.readData(ofLength: bufferSize)
                        if data.isEmpty {
                            try? writeHandle.close()
                            keepReading = false
                            continuation.resume()
                            return
                        }

                        writeHandle.write(data)
                        let written = Int64(data.count)

                        Task {
                            let newTotal = await counter.add(written)
                            progressHandler?(newTotal, totalSize)
                        }
                    }
                }
            }
        }

        try? sourceHandle.close()

        try await process.runAndWait()

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw AuthOpenError.authopenFailed(errorString)
        }
    }
}

/// Thread-safe byte counter using actor isolation
private actor ByteCounter {
    private var value: Int64 = 0

    func add(_ amount: Int64) -> Int64 {
        value += amount
        return value
    }
}
