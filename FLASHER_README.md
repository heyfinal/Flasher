# Flasher - Bootable USB Creator for macOS

A modern, native macOS application for creating bootable USB drives, inspired by Rufus.io but built specifically for macOS using Swift and SwiftUI.

## Features

### ✅ Implemented Features

- **Disk Detection & Selection**
  - Automatic detection of removable USB drives
  - Safety checks to prevent accidental formatting of system disks
  - Real-time disk information (size, filesystem, mount status)
  - Refresh capability to detect newly inserted drives

- **ISO/Image File Support**
  - Support for .iso, .img, and .dmg files
  - File selection with native macOS file picker
  - Image validation and integrity checks
  - Checksum calculation (MD5, SHA-1, SHA-256)

- **Partition Schemes**
  - MBR (Master Boot Record) - For BIOS/Legacy systems
  - GPT (GUID Partition Table) - For UEFI systems
  - APM (Apple Partition Map) - For older Macs

- **File System Options**
  - FAT32 - Most compatible, 4GB file limit
  - exFAT - Modern, no file size limit
  - NTFS - Windows native
  - APFS - macOS native
  - HFS+ - Legacy macOS
  - ext4 - Linux native (read-only on macOS)

- **Boot Mode Selection**
  - BIOS/Legacy boot
  - UEFI boot
  - Hybrid boot (compatible with both)

- **Advanced Features**
  - **Progress Tracking** - Real-time progress display with speed and ETA
  - **Verification** - Optional verification after write
  - **Bad Block Detection** - Check disk for errors before writing
  - **Checksum Validation** - Verify image integrity before writing
  - **Safe Erase** - Confirmation dialogs to prevent accidental data loss

## Architecture

### Modern Swift/SwiftUI Design

The application uses a clean MVVM (Model-View-ViewModel) architecture:

```
Flasher/
├── Models/
│   ├── DiskInfo.swift          # Disk information model
│   └── ImageInfo.swift         # Image file information model
├── Managers/
│   ├── DiskManager.swift       # Disk operations (diskutil)
│   ├── ImageManager.swift      # Image file handling & checksums
│   ├── WriterManager.swift     # Disk writing (dd)
│   └── BadBlockChecker.swift   # Bad block detection
└── Views/
    └── MainView.swift          # Main SwiftUI interface
```

### Key Technologies

- **Swift 5.9+** with modern async/await
- **SwiftUI** for native macOS UI
- **AppKit** integration for file dialogs
- **CryptoKit** for checksum calculation
- **Process API** for diskutil and dd integration

## Requirements

- macOS 15.0 or later
- Xcode 15.0 or later (for building)
- Administrator privileges (for disk operations)

## Building

### Using Swift Package Manager

```bash
cd FlasherPackage
swift build
```

### Using Xcode

1. Open `Flasher.xcworkspace` in Xcode
2. Select the `Flasher` scheme
3. Build and run (⌘R)

## Security & Permissions

### Required Permissions

1. **Full Disk Access** - For reading disk information
2. **Administrator Privileges** - For disk erase and write operations

The app will prompt for administrator credentials when performing disk operations.

### Safety Features

- **Removable Disk Only** - By default, only shows removable disks
- **System Disk Protection** - Prevents formatting of internal/system disks
- **Confirmation Dialogs** - Double confirmation before destructive operations
- **Read-Only Detection** - Detects and warns about read-only disks

## Usage

### Basic Workflow

1. **Insert USB Drive** - Connect the USB drive you want to make bootable
2. **Select Device** - Choose the target USB drive from the list
3. **Select Image** - Click "Select ISO or Image" and choose your bootable image file
4. **Configure Options**:
   - Choose partition scheme (GPT for UEFI, MBR for BIOS)
   - Select filesystem (FAT32 for compatibility, exFAT for large files)
   - Choose boot mode (UEFI, BIOS, or Hybrid)
   - Set volume name
   - Enable/disable verification
5. **Start** - Click START and confirm the warning dialog
6. **Wait** - Monitor progress until completion

### Advanced Features

#### Checksum Verification

To verify image integrity before writing:

1. Select your image file
2. In the advanced options, enter expected checksum
3. Choose algorithm (MD5, SHA-1, or SHA-256)
4. Click "Verify" to calculate and compare

#### Bad Block Check

To check disk for errors:

1. Select target disk
2. Click "Check Bad Blocks"
3. Wait for scan to complete
4. View results before proceeding with write

## Comparison with Rufus

### Features in Flasher (Rufus Equivalent)

| Feature | Rufus | Flasher | Status |
|---------|-------|----------|--------|
| ISO Selection | ✅ | ✅ | Complete |
| Partition Scheme | MBR/GPT | MBR/GPT/APM | Complete |
| File System | FAT32/NTFS/exFAT/etc | FAT32/NTFS/exFAT/APFS/HFS+/ext4 | Complete |
| Boot Mode | BIOS/UEFI | BIOS/UEFI/Hybrid | Complete |
| Progress Tracking | ✅ | ✅ | Complete |
| Verification | ✅ | ✅ | Complete |
| Checksum | MD5/SHA1/SHA256 | MD5/SHA1/SHA256 | Complete |
| Bad Block Check | ✅ | ✅ | Complete |
| Windows To Go | ✅ | ❌ | Not applicable (macOS) |
| Persistent Storage | ✅ | ⚠️ | Future enhancement |

### Flasher Advantages

- **Native macOS Integration** - Uses AppKit and SwiftUI for true macOS experience
- **Modern Swift** - Built with latest Swift features (async/await, actors)
- **Safety First** - Multiple layers of protection against accidental data loss
- **APFS Support** - Native support for Apple's modern filesystem
- **Clean Architecture** - Easy to maintain and extend

## Implementation Details

### Disk Operations

The app uses macOS's built-in command-line tools:

- **diskutil** - For disk enumeration, unmounting, and erasing
- **dd** - For writing raw disk images
- **hdiutil** - For handling DMG files (future enhancement)

### Progress Tracking

Progress is calculated by:
1. Monitoring `dd` stderr output
2. Parsing bytes written
3. Calculating percentage, speed, and ETA
4. Updating UI in real-time via SwiftUI `@Published` properties

### Error Handling

Comprehensive error handling at multiple levels:
- File validation before operations
- Disk safety checks before formatting
- Process execution monitoring
- User-friendly error messages

## Known Limitations

1. **macOS Only** - Not cross-platform (by design)
2. **USB Drives Only** - Only shows removable drives for safety
3. **WIM Split Tooling** - FAT32 Windows ISOs need `wimlib-imagex` for automatic WIM splitting
4. **Kali Persistence Tooling** - Kali persistence requires `mkfs.ext4` (e2fsprogs)

## Future Enhancements

- [ ] ISO download from official sources
- [ ] Multi-boot support
- [ ] Custom partition layouts
- [ ] Disk cloning
- [ ] Batch operations

## Development

### Code Style

- Swift naming conventions
- SwiftUI best practices
- Async/await for all I/O operations
- @MainActor for UI updates
- Comprehensive error handling

### Testing

```bash
# Run tests
cd FlasherPackage
swift test
```

### Contributing

This is a personal project but contributions are welcome! Areas for improvement:

1. Additional filesystem support
2. Enhanced progress reporting
3. Improved error recovery
4. Unit tests
5. UI/UX improvements

## Troubleshooting

### "Permission Denied" Errors

- Grant Full Disk Access in System Settings > Privacy & Security
- Run the app with administrator privileges
- Run the app with administrator privileges when flashing

```bash
sudo /path/to/Flasher.app/Contents/MacOS/Flasher
```

Or use the admin script:

```bash
scripts/run-as-admin.sh /path/to/Flasher.app
```

### "Disk is Busy" Errors

- Eject the disk in Finder first
- Close any applications accessing the disk
- Wait a moment and try again

### "Invalid Image" Errors

- Ensure the image file is a valid ISO, IMG, or DMG
- Check file permissions
- Verify the file isn't corrupted (use checksum)

### "WIM Split Tool Missing"

- Install wimlib: `scripts/install-wimlib.sh`
- Ensure `wimlib-imagex` is available in your PATH

### "Kali Persistence Tool Missing"

- Install e2fsprogs: `scripts/install-e2fsprogs.sh`
- Ensure `mkfs.ext4` is available in your PATH

## Kali Live Persistence

Kali's docs specify that persistence uses an **ext4** partition labeled **persistence** and a `persistence.conf` file containing `/ union`. Flasher will:

1. Write the Kali Live ISO in raw mode
2. Add a new partition in free space
3. Format it as ext4 with label `persistence`
4. Seed `persistence.conf` with `/ union`

Reference: https://www.kali.org/docs/usb/usb-persistence/

### Build Errors

- Ensure Xcode Command Line Tools are installed
- Use Xcode 15.0 or later
- Clean build folder (⌘⇧K in Xcode)

## Credits

- **Inspired by**: Rufus.io by Pete Batard
- **Built with**: Swift, SwiftUI, AppKit
- **Icons**: SF Symbols by Apple
- **Author**: Claude Code (AI-assisted development)

## License

MIT License - Feel free to use, modify, and distribute.

## Disclaimer

⚠️ **WARNING**: This application can permanently erase data from disks. Always double-check your selections before confirming operations. The authors are not responsible for any data loss.

Use at your own risk. Always backup important data before performing disk operations.
