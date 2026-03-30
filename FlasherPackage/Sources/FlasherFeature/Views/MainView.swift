import SwiftUI
import AppKit

struct MainView: View {
    @StateObject private var diskManager = DiskManager()
    @StateObject private var imageManager = ImageManager()
    @StateObject private var writerManager = WriterManager()

    @State private var selectedDisk: DiskInfo?
    @State private var selectedPartitionScheme: PartitionScheme = .gpt
    @State private var selectedFilesystem: FileSystem = .fat32
    @State private var selectedBootMode: BootMode = .uefi
    @State private var volumeName: String = "BOOTABLE"
    @State private var formatBeforeWrite: Bool = true
    @State private var checkBadBlocks: Bool = false
    @State private var verifyAfterWrite: Bool = true
    @State private var writeMethod: WriteMethod = .auto
    @State private var persistenceEnabled: Bool = false
    @State private var persistenceSizeGB: Int = 2
    @State private var persistenceMode: PersistenceMode = .generic
    @State private var showDevicePicker: Bool = false
    @State private var showAdvancedOptions: Bool = false
    @State private var selectedPreset: LinuxPreset?
    @State private var showAlert: Bool = false
    @State private var alertMessage: String = ""
    @State private var alertTitle: String = ""
    @State private var showFullDiskAccessPrompt: Bool = false
    @State private var hasFullDiskAccess: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            // Main content
            VStack(spacing: 12) {
                topCardsView

                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("Advanced Options", isExpanded: $showAdvancedOptions) {
                        optionsPanel
                            .padding(.top, 6)
                    }
                    .font(.headline)
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 12)
            }
            .padding(.top, 12)

            // Bottom progress area
            if writerManager.isWriting {
                progressView
            }
        }
        .background(backgroundView)
        .frame(minWidth: 360, idealWidth: 440)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .alert("Full Disk Access Required", isPresented: $showFullDiskAccessPrompt) {
            Button("Open Settings") {
                FullDiskAccessChecker.openFullDiskAccessSettings()
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text(FullDiskAccessChecker.explanationMessage + "\n\n" + FullDiskAccessChecker.instructionsMessage)
        }
        .onAppear {
            showAdvancedOptions = false
            resizeWindowToFit(animated: false)
            checkFullDiskAccessStatus()
        }
        .onChange(of: showAdvancedOptions) { _, _ in
            resizeWindowToFit(animated: true)
        }
        .sheet(isPresented: $showDevicePicker) {
            deviceSelectionPanel
                .frame(minWidth: 380, minHeight: 480)
        }
        .task {
            await refreshDisks()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text("Flasher")
                .font(.title3)
                .fontWeight(.semibold)

            Text("USB Utility")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Device Selection Panel

    private var deviceSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Select Device")
                    .font(.headline)

                Spacer()

                Button(action: { Task { await refreshDisks() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(diskManager.isScanning)
            }
            .padding(.horizontal)
            .padding(.top)

            if diskManager.isScanning {
                ProgressView("Scanning devices...")
                    .padding()
            } else if diskManager.availableDisks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No removable devices found")
                        .foregroundColor(.secondary)
                    Text("Insert a USB drive and click refresh")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(diskManager.availableDisks) { disk in
                            Button(action: {
                                if disk.isSafeToFormat {
                                    selectedDisk = disk
                                    showDevicePicker = false
                                } else {
                                    alertTitle = "Unsafe Disk"
                                    alertMessage = "That device is marked unsafe to format. Use a removable USB drive."
                                    showAlert = true
                                }
                            }) {
                                DiskRow(disk: disk, isSelected: selectedDisk?.id == disk.id)
                            }
                            .buttonStyle(.plain)
                            .opacity(disk.isSafeToFormat ? 1.0 : 0.5)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .padding(12)
    }

    // MARK: - Options Panel

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            linuxPresetSection

            Divider()

            // Partition scheme
            optionSection(title: "Partition Scheme") {
                Picker("", selection: $selectedPartitionScheme) {
                    ForEach(PartitionScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                }
                .pickerStyle(.menu)
            }

            // Filesystem
            optionSection(title: "File System") {
                Picker("", selection: $selectedFilesystem) {
                    ForEach(FileSystem.allCases) { fs in
                        Text(fs.displayName).tag(fs)
                    }
                }
                .pickerStyle(.menu)
            }

            // Write method
            optionSection(title: "Write Method") {
                Picker("", selection: $writeMethod) {
                    ForEach(WriteMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.menu)
            }

            // Boot mode
            optionSection(title: "Boot Mode") {
                Picker("", selection: $selectedBootMode) {
                    ForEach(BootMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            // Volume name
            optionSection(title: "Volume Name") {
                TextField("BOOTABLE", text: $volumeName)
                    .textFieldStyle(.roundedBorder)
            }

            // Options
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Format before write", isOn: $formatBeforeWrite)
                Toggle("Check device for bad blocks (quick)", isOn: $checkBadBlocks)
                Toggle("Verify after write", isOn: $verifyAfterWrite)
                Text("Recommended: Ensures data integrity")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Create persistence partition", isOn: $persistenceEnabled)
                if persistenceEnabled {
                    Stepper(value: $persistenceSizeGB, in: 1...64) {
                        Text("Persistence size: \(persistenceSizeGB) GB")
                    }
                    .frame(maxWidth: 240)
                    Slider(value: Binding(
                        get: { Double(persistenceSizeGB) },
                        set: { persistenceSizeGB = Int($0) }
                    ), in: 1...64, step: 1)
                    .frame(maxWidth: 240)
                    Text("Kali Live uses ext4 labeled \"persistence\" with a persistence.conf file.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if formatBeforeWrite && !selectedFilesystem.isSupportedByDiskutil {
                Text("Selected file system isn't supported by diskutil on macOS.")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Image Selection

    private var imageSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Boot Selection")
                .font(.headline)

            if let image = imageManager.selectedImage {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(image.filename)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(image.sizeString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Change") {
                        Task {
                            _ = await imageManager.selectImage()
                        }
                    }
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
            } else {
                Button(action: {
                    Task {
                        _ = await imageManager.selectImage()
                    }
                }) {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text("Select ISO or Image")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Progress View

    private var progressView: some View {
        VStack(spacing: 8) {
            if let progress = writerManager.progress {
                HStack {
                    Text(progress.status)
                        .font(.subheadline)
                    Spacer()
                    Button("Cancel") {
                        writerManager.cancelWrite()
                    }
                    .buttonStyle(.bordered)
                    Text(String(format: "%.1f%%", progress.percentage))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if progress.isIndeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress.percentage, total: 100.0)
                }

                HStack {
                    Text("Speed: \(progress.speedString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Remaining: \(progress.remainingTimeString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            if let disk = selectedDisk {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Target: \(disk.displayName)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("⚠️ All data on this device will be destroyed")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer()

            if writerManager.isWriting {
                Button("Cancel") {
                    writerManager.cancelWrite()
                }
                .buttonStyle(.bordered)
            } else {
                Button("START") {
                    startWrite()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartWrite)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Helper Views

    private func optionSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.5)))
    }

    private var linuxPresetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download Linux ISO")
                .font(.subheadline)
                .fontWeight(.medium)
            Picker("", selection: $selectedPreset) {
                Text("Select a preset").tag(LinuxPreset?.none)
                ForEach(imageManager.linuxPresets) { preset in
                    Text(preset.displayName).tag(LinuxPreset?.some(preset))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button("Download & Select") {
                    guard let preset = selectedPreset else { return }
                    Task {
                        _ = await imageManager.downloadPreset(preset)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPreset == nil || imageManager.isDownloading)

                if imageManager.isDownloading {
                    ProgressView(value: imageManager.downloadProgress, total: 1.0)
                        .frame(maxWidth: 160)
                }
            }

            if !imageManager.downloadStatus.isEmpty {
                Text(imageManager.downloadStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.5)))
    }

    private var topCardsView: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                cardSelectImage
                cardSelectTarget
                cardFlash
            }
            VStack(spacing: 10) {
                cardSelectImage
                cardSelectTarget
                cardFlash
            }
        }
        .padding(.horizontal, 12)
    }

    private var cardSelectImage: some View {
        actionCard(title: "1. Select Image", icon: "doc.fill") {
            imageSelectionSection
        }
    }

    private var cardSelectTarget: some View {
        actionCard(title: "2. Select Target", icon: "externaldrive.fill") {
            VStack(alignment: .leading, spacing: 6) {
                if let disk = selectedDisk {
                    Text(disk.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("USB • \(disk.sizeString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("No drive selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("Choose Drive") {
                    showDevicePicker = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var cardFlash: some View {
        actionCard(title: "3. Flash", icon: "bolt.fill") {
            VStack(alignment: .leading, spacing: 6) {
                if !hasFullDiskAccess {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Full Disk Access required")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Button("Grant Access") {
                        FullDiskAccessChecker.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.bordered)
                    Button("Check Again") {
                        checkFullDiskAccessStatus()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                } else {
                    Text(canStartWrite ? "Ready to flash" : "Complete steps 1-2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Flash") {
                        startWrite()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartWrite || writerManager.isWriting)
                }
            }
        }
    }

    private func actionCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)
                )
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                    Text(title)
                        .font(.headline)
                }
                content()
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: Color.black.opacity(0.28), radius: 18, y: 10)
    }

    // MARK: - Actions

    private func refreshDisks() async {
        do {
            _ = try await diskManager.listDisks()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == 3587 {
                return
            }
            alertTitle = "Error"
            alertMessage = detailedErrorMessage(error)
            showAlert = true
        }
    }

    /// Check FDA status and prompt user if not granted.
    /// This is checked every time the app appears, not just once.
    private func checkFullDiskAccessStatus() {
        hasFullDiskAccess = FullDiskAccessChecker.hasFullDiskAccess()

        if !hasFullDiskAccess {
            // Show prompt after a short delay for better UX
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                showFullDiskAccessPrompt = true
            }
        }
    }

    private func resizeWindowToFit(animated: Bool) {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            let fittingSize = window.contentView?.fittingSize ?? NSSize(width: 440, height: 360)
            let minHeight: CGFloat = 430
            let maxHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? fittingSize.height
            let targetHeight = min(max(fittingSize.height.rounded(.up), minHeight), maxHeight - 80)
            let targetWidth = max(window.contentView?.frame.width ?? fittingSize.width, 360)
            let targetSize = NSSize(width: targetWidth, height: targetHeight)
            window.minSize = NSSize(width: 360, height: minHeight)
            let currentHeight = window.contentView?.frame.height ?? 0
            if abs(currentHeight - targetHeight) < 1 {
                return
            }
            if animated {
                window.animator().setContentSize(targetSize)
            } else {
                window.setContentSize(targetSize)
            }
        }
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(NSColor.windowBackgroundColor),
                    Color(NSColor.windowBackgroundColor).opacity(0.65)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.28),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 200
            )
            RadialGradient(
                colors: [
                    Color.blue.opacity(0.18),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 30,
                endRadius: 220
            )
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .opacity(0.18)
                .padding(6)
        }
        .ignoresSafeArea()
    }

    private var canStartWrite: Bool {
        guard hasFullDiskAccess else { return false }
        guard let disk = selectedDisk else { return false }
        guard disk.isSafeToFormat else { return false }
        guard let image = imageManager.selectedImage, image.isValidImage else { return false }
        guard !writerManager.isWriting else { return false }
        if formatBeforeWrite && !selectedFilesystem.isSupportedByDiskutil {
            return false
        }
        return true
    }

    private func startWrite() {
        guard let disk = selectedDisk, let image = imageManager.selectedImage else {
            return
        }

        if !disk.isSafeToFormat {
            alertTitle = "Unsafe Disk"
            alertMessage = "The selected disk is not safe to format."
            showAlert = true
            return
        }

        if formatBeforeWrite && !selectedFilesystem.isSupportedByDiskutil {
            alertTitle = "Unsupported File System"
            alertMessage = "The selected file system is not supported by diskutil on macOS."
            showAlert = true
            return
        }

        // Show confirmation
        let alert = NSAlert()
        alert.messageText = "⚠️ Warning: All Data Will Be Destroyed"
        alert.informativeText = "This will permanently erase all data on \(disk.displayName). This action cannot be undone.\n\nAre you sure you want to continue?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Yes, Erase and Write")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            Task {
                do {
                    let isKali = await writerManager.isKaliLiveISO(imageURL: image.url)
                    let resolvedPersistenceMode: PersistenceMode
                    if persistenceEnabled {
                        resolvedPersistenceMode = isKali ? .kali : .generic
                    } else {
                        resolvedPersistenceMode = .none
                    }

                    let options = WriteOptions(
                        partitionScheme: selectedPartitionScheme,
                        filesystem: selectedFilesystem,
                        bootMode: selectedBootMode,
                        volumeName: volumeName.isEmpty ? "UNTITLED" : volumeName,
                        formatBeforeWrite: formatBeforeWrite || writeMethod == .fileCopy,
                        verifyAfterWrite: verifyAfterWrite,
                        checkBadBlocks: checkBadBlocks,
                        persistenceEnabled: persistenceEnabled,
                        persistenceSizeGB: persistenceSizeGB,
                        persistenceMode: resolvedPersistenceMode,
                        writeMethod: writeMethod
                    )

                    let result = try await writerManager.writeImage(
                        imageURL: image.url,
                        toDisk: disk.bsdName,
                        options: options
                    )

                    alertTitle = result.isSuccess ? "Success" : "Error"
                    alertMessage = result.message
                    if !result.isSuccess, let detail = writerManager.lastCommandOutput, !detail.isEmpty {
                        alertMessage += "\n\nDetails:\n\(detail)"
                    }
                    showAlert = true
                    // Note: Don't show FDA prompt again here - user already dealt with it on launch

                    if result.isSuccess {
                        await refreshDisks()
                    }
                } catch {
                    alertTitle = "Error"
                    alertMessage = detailedErrorMessage(error)
                    if let detail = writerManager.lastCommandOutput, !detail.isEmpty {
                        alertMessage += "\n\nDetails:\n\(detail)"
                    }
                    showAlert = true
                }
            }
        }
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        var message = error.localizedDescription
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            message += "\n\nCocoa error \(nsError.code)."
            if nsError.code == 3587 {
                message += "\nThis usually means macOS blocked disk access. Grant Full Disk Access to Flasher and retry."
            }
        }
        return message
    }

    // Helper install removed by request
}

// MARK: - Disk Row Component

struct DiskRow: View {
    let disk: DiskInfo
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: disk.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                .foregroundColor(disk.isSafeToFormat ? .blue : .red)

            VStack(alignment: .leading, spacing: 4) {
                Text(disk.volumeName ?? disk.bsdName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("\(disk.bsdName) - \(disk.sizeString)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let fs = disk.filesystem {
                    Text(fs)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !disk.isSafeToFormat {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
    }
}
