import Foundation
import CryptoKit
import AppKit
import UniformTypeIdentifiers

/// Manages ISO and disk image files
@MainActor
class ImageManager: ObservableObject {
    @Published var selectedImage: ImageInfo?
    @Published var isValidating: Bool = false
    @Published var validationProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStatus: String = ""

    /// Select an image file
    func selectImage() async -> ImageInfo? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let isoType = UTType(filenameExtension: "iso") ?? UTType.data
        let imgType = UTType(filenameExtension: "img") ?? UTType.data
        let dmgType = UTType(filenameExtension: "dmg") ?? UTType.data
        panel.allowedContentTypes = [isoType, imgType, dmgType, UTType.data]
        panel.message = "Select an ISO or disk image file"

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let url = panel.url else {
            return nil
        }

        return await createImageInfo(from: url)
    }

    var linuxPresets: [LinuxPreset] {
        [
            LinuxPreset(
                id: "kali-live",
                name: "Kali Live (amd64)",
                url: URL(string: "https://cdimage.kali.org/kali-2025.4/kali-linux-2025.4-live-amd64.iso.torrent")!,
                filename: "kali-linux-2025.4-live-amd64.iso"
            ),
            LinuxPreset(
                id: "ubuntu-2404",
                name: "Ubuntu 24.04 LTS Live (amd64)",
                url: URL(string: "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-desktop-amd64.iso")!,
                filename: "ubuntu-24.04.1-desktop-amd64.iso"
            ),
            LinuxPreset(
                id: "fedora-40",
                name: "Fedora Workstation Live 40 (amd64)",
                url: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Workstation/x86_64/iso/Fedora-Workstation-Live-x86_64-40-1.14.iso")!,
                filename: "Fedora-Workstation-Live-x86_64-40-1.14.iso"
            ),
            LinuxPreset(
                id: "debian-12-live",
                name: "Debian 12 Live (GNOME, amd64)",
                url: URL(string: "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.6.0-amd64-gnome.iso")!,
                filename: "debian-live-12.6.0-amd64-gnome.iso"
            ),
            LinuxPreset(
                id: "mint-217",
                name: "Linux Mint 21.3 Cinnamon (amd64)",
                url: URL(string: "https://mirrors.edge.kernel.org/linuxmint/stable/21.3/linuxmint-21.3-cinnamon-64bit.iso")!,
                filename: "linuxmint-21.3-cinnamon-64bit.iso"
            ),
            LinuxPreset(
                id: "parrot-61",
                name: "Parrot OS Home 6.1 (amd64)",
                url: URL(string: "https://deb.parrot.sh/parrot/iso/6.1/Parrot-home-6.1_amd64.iso")!,
                filename: "Parrot-home-6.1_amd64.iso"
            ),
            LinuxPreset(
                id: "pop-2404",
                name: "Pop!_OS 24.04 LTS (amd64)",
                url: URL(string: "https://iso.pop-os.org/24.04/amd64/generic/22/pop-os_24.04_amd64_generic_22.iso")!,
                filename: "pop-os_24.04_amd64_generic_22.iso"
            )
        ]
    }

    func downloadPreset(_ preset: LinuxPreset) async -> ImageInfo? {
        guard !isDownloading else { return nil }
        isDownloading = true
        downloadProgress = 0.0
        downloadStatus = "Starting download..."
        defer {
            isDownloading = false
        }

        do {
            let downloadedURL: URL
            if preset.url.pathExtension.lowercased() == "torrent" {
                downloadedURL = try await downloadTorrentPreset(preset)
            } else {
                let destination = try downloadDestinationURL(for: preset.filename)
                downloadedURL = try await downloadFile(from: preset.url, to: destination)
            }
            downloadStatus = "Download complete"
            return await createImageInfo(from: downloadedURL)
        } catch {
            downloadStatus = "Download failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func downloadDestinationURL(for filename: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let folder = downloads.appendingPathComponent("Flasher", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent(filename)
    }

    private func downloadFile(from url: URL, to destination: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(destinationURL: destination) { [weak self] progress, status in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.downloadStatus = status
                }
            } completion: { result in
                continuation.resume(with: result)
            }

            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Flasher/1.0 (macOS)",
                "Accept": "*/*"
            ]
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private func downloadTorrentPreset(_ preset: LinuxPreset) async throws -> URL {
        guard let aria2cPath = findAria2cPath() else {
            throw NSError(domain: "Flasher", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "aria2c is required for torrent downloads. Install it with Homebrew: brew install aria2"
            ])
        }

        let destination = try downloadDestinationURL(for: preset.filename)
        let torrentURL = destination.deletingPathExtension().appendingPathExtension("torrent")
        let torrentData = try await downloadTorrentFile(from: preset.url)
        try torrentData.write(to: torrentURL, options: .atomic)

        downloadStatus = "Starting torrent download..."
        try await runAria2c(torrentURL: torrentURL, outputURL: destination, aria2cPath: aria2cPath)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let size = attributes[.size] as? Int64 ?? 0
        if size < 50 * 1024 * 1024 {
            throw URLError(.cannotDecodeContentData)
        }
        downloadProgress = 1.0
        return destination
    }

    private func downloadTorrentFile(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        if data.count < 128 {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    private func runAria2c(torrentURL: URL, outputURL: URL, aria2cPath: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: aria2cPath)
            process.arguments = [
                "--seed-time=0",
                "--summary-interval=1",
                "--console-log-level=notice",
                "--auto-file-renaming=false",
                "--allow-overwrite=true",
                "--dir=\(outputURL.deletingLastPathComponent().path)",
                "--out=\(outputURL.lastPathComponent)",
                torrentURL.path
            ]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let handleOutput: @Sendable (Data) -> Void = { [weak self] data in
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
                Task { @MainActor in
                    self?.parseAria2cProgress(text)
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                handleOutput(handle.availableData)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                handleOutput(handle.availableData)
            }

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errorOutput = String(
                        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? "aria2c failed"
                    continuation.resume(throwing: NSError(
                        domain: "Flasher",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: errorOutput]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func parseAria2cProgress(_ text: String) {
        if let percentIndex = text.firstIndex(of: "%") {
            let prefix = text[..<percentIndex]
            if let numberString = prefix.split(whereSeparator: { !$0.isNumber }).last,
               let value = Double(numberString) {
                downloadProgress = value / 100.0
                downloadStatus = "Downloading... \(Int(value))%"
                return
            }
        }
        if text.lowercased().contains("error") {
            downloadStatus = "Download error"
            return
        }
        if downloadStatus.isEmpty {
            downloadStatus = "Downloading..."
        }
    }

    private func findAria2cPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
            "/usr/bin/aria2c"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Create ImageInfo from URL
    private func createImageInfo(from url: URL) async -> ImageInfo? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes[.size] as? Int64 ?? 0
            let createdDate = attributes[.creationDate] as? Date

            let info = ImageInfo(
                id: UUID(),
                url: url,
                filename: url.lastPathComponent,
                size: size,
                sizeString: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                checksumMD5: nil,
                checksumSHA256: nil,
                createdDate: createdDate
            )

            selectedImage = info
            return info
        } catch {
            print("Error getting file info: \(error)")
            return nil
        }
    }

    /// Calculate checksum for a file
    func calculateChecksum(url: URL, algorithm: ChecksumAlgorithm) async throws -> String {
        isValidating = true
        validationProgress = 0.0
        defer {
            isValidating = false
            validationProgress = 0.0
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        let bufferSize = 1024 * 1024 // 1MB buffer
        let totalSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
        var bytesRead: Int64 = 0

        switch algorithm {
        case .md5:
            var hasher = Insecure.MD5()
            while autoreleasepool(invoking: {
                let data = fileHandle.readData(ofLength: bufferSize)
                if !data.isEmpty {
                    hasher.update(data: data)
                    bytesRead += Int64(data.count)
                    validationProgress = Double(bytesRead) / Double(totalSize)
                    return true
                }
                return false
            }) {}
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()

        case .sha1:
            var hasher = Insecure.SHA1()
            while autoreleasepool(invoking: {
                let data = fileHandle.readData(ofLength: bufferSize)
                if !data.isEmpty {
                    hasher.update(data: data)
                    bytesRead += Int64(data.count)
                    validationProgress = Double(bytesRead) / Double(totalSize)
                    return true
                }
                return false
            }) {}
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()

        case .sha256:
            var hasher = SHA256()
            while autoreleasepool(invoking: {
                let data = fileHandle.readData(ofLength: bufferSize)
                if !data.isEmpty {
                    hasher.update(data: data)
                    bytesRead += Int64(data.count)
                    validationProgress = Double(bytesRead) / Double(totalSize)
                    return true
                }
                return false
            }) {}
            let digest = hasher.finalize()
            return digest.map { String(format: "%02hhx", $0) }.joined()
        }
    }

    /// Validate image file integrity
    func validateImage(expectedChecksum: String?, algorithm: ChecksumAlgorithm) async throws -> Bool {
        guard let image = selectedImage else {
            return false
        }

        guard let expected = expectedChecksum, !expected.isEmpty else {
            // No expected checksum provided, just calculate and return true
            _ = try await calculateChecksum(url: image.url, algorithm: algorithm)
            return true
        }

        let calculated = try await calculateChecksum(url: image.url, algorithm: algorithm)
        return calculated.lowercased() == expected.lowercased()
    }
}

final class DownloadDelegate: NSObject, @unchecked Sendable {
    private let destinationURL: URL
    private let progressHandler: (Double, String) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var responseError: Error?
    private var expectedContentLength: Int64 = 0
    private let minimumDownloadSize: Int64 = 50 * 1024 * 1024

    init(
        destinationURL: URL,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.destinationURL = destinationURL
        self.progressHandler = progress
        self.completion = completion
    }
}

extension DownloadDelegate: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress, "Downloading... \(Int(progress * 100))%")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let size = attributes[.size] as? Int64 ?? 0
            if expectedContentLength > 0 && size < expectedContentLength {
                let error = URLError(.networkConnectionLost)
                responseError = error
                completion(.failure(error))
                return
            }
            if size > 0 && size < minimumDownloadSize {
                let error = URLError(.cannotDecodeContentData)
                responseError = error
                completion(.failure(error))
                return
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            completion(.success(destinationURL))
        } catch {
            completion(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if responseError != nil {
            return
        }
        if let error {
            completion(.failure(error))
        }
    }
}

extension DownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let error = URLError(.badServerResponse)
            responseError = error
            completion(.failure(error))
            completionHandler(.cancel)
            return
        }
        if let mimeType = response.mimeType, mimeType.hasPrefix("text/") {
            let error = URLError(.cannotDecodeContentData)
            responseError = error
            completion(.failure(error))
            completionHandler(.cancel)
            return
        }
        expectedContentLength = response.expectedContentLength
        completionHandler(.allow)
    }
}
