import Foundation
import AppKit

/// Utility for detecting Full Disk Access (FDA) status on macOS.
/// Uses Apple's TCC (Transparency Consent and Control) system behavior.
///
/// Key insight: `FileManager.isReadableFile(atPath:)` does NOT trigger TCC checks.
/// We must actually attempt to open/read the file to get an accurate FDA status.
enum FullDiskAccessChecker {

    /// Paths protected by Full Disk Access, in order of preference.
    /// These are directories that require FDA to access.
    private static let protectedPaths: [String] = [
        // macOS 12+ recommended path (most reliable)
        NSHomeDirectory() + "/Library/Containers/com.apple.stocks",
        // Safari data (very common, reliable)
        NSHomeDirectory() + "/Library/Safari",
        // Mail data
        NSHomeDirectory() + "/Library/Mail",
        // Messages data
        NSHomeDirectory() + "/Library/Messages",
        // System-level protected path (fallback)
        "/Library/Application Support/com.apple.TCC"
    ]

    /// Check if the app has Full Disk Access permission.
    /// This performs an actual file operation to trigger TCC, not just a metadata check.
    ///
    /// - Returns: `true` if FDA is granted, `false` otherwise
    static func hasFullDiskAccess() -> Bool {
        for path in protectedPaths {
            // First check if path exists (this doesn't trigger TCC)
            if FileManager.default.fileExists(atPath: path) {
                // Now actually try to read - THIS triggers TCC
                if canActuallyRead(path: path) {
                    return true
                } else {
                    // Path exists but we can't read it = no FDA
                    return false
                }
            }
        }

        // If none of the protected paths exist, try reading a known protected file
        // This handles edge cases where user deleted Safari, etc.
        return canReadTCCDatabase()
    }

    /// Attempt to actually read from a path (triggers TCC check).
    private static func canActuallyRead(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)

        // For directories, try to enumerate contents
        if isDirectory(path: path) {
            do {
                _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                return true
            } catch {
                return false
            }
        }

        // For files, try to open for reading
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    /// Check if path is a directory.
    private static func isDirectory(path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    /// Fallback: Try to read the TCC database directly.
    /// Note: Apple says this is "not API" but it's a reliable fallback.
    private static func canReadTCCDatabase() -> Bool {
        let tccPath = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"

        guard FileManager.default.fileExists(atPath: tccPath) else {
            // TCC.db doesn't exist (unusual), assume no FDA
            return false
        }

        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: tccPath))
            try handle.close()
            return true
        } catch {
            return false
        }
    }

    /// Request FDA by opening System Preferences to the correct pane.
    /// The user must manually toggle the switch for this app.
    @MainActor
    static func openFullDiskAccessSettings() {
        // Deep link to Privacy & Security > Full Disk Access
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Get a user-friendly message explaining what FDA is needed for.
    static var explanationMessage: String {
        """
        Full Disk Access is required to:

        • Write disk images to USB drives
        • Verify written data matches the source
        • Access raw disk devices

        Without this permission, disk writing may fail or produce incomplete results.
        """
    }

    /// Get instructions for enabling FDA.
    static var instructionsMessage: String {
        """
        To enable Full Disk Access:

        1. Click "Open System Settings"
        2. Find "Flasher" in the list
        3. Toggle the switch ON
        4. Restart Flasher when prompted

        Important: For FDA to persist, run Flasher from /Applications (not from Xcode or Downloads).
        """
    }
}
