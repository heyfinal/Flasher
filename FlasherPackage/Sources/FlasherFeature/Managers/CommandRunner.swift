import Foundation

struct CommandResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

enum CommandRunner {
    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func run(
        path: String,
        arguments: [String],
        requiresPrivilege: Bool
    ) async throws -> CommandResult {
        let process = Process()
        if requiresPrivilege {
            let command = ([path] + arguments).map(shellEscape).joined(separator: " ")
            let script = "do shell script \(appleScriptString("\(command) 2>&1")) with administrator privileges"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
        } else {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try await process.runAndWait()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            stderr: errorPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }

    /// Run multiple commands in a single privileged session.
    /// This prevents macOS from auto-remounting disks between unmount and dd operations.
    static func runChained(
        commands: [(path: String, arguments: [String])],
        requiresPrivilege: Bool
    ) async throws -> CommandResult {
        if requiresPrivilege {
            // Chain all commands with && so they run in sequence
            let chainedCommand = commands.map { cmd in
                ([cmd.path] + cmd.arguments).map(shellEscape).joined(separator: " ")
            }.joined(separator: " && ")

            print("[Flasher Debug v2] runChained: Building SINGLE privileged command string")
            print("[Flasher Debug v2] Chained command: \(chainedCommand)")

            // First try osascript with admin privileges
            let script = "do shell script \(appleScriptString("\(chainedCommand) 2>&1")) with administrator privileges"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try await process.runAndWait()

            let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()

            // Check if it failed with "Operation not permitted" - need Full Disk Access
            let output = String(data: stdout, encoding: .utf8) ?? ""
            let error = String(data: stderr, encoding: .utf8) ?? ""
            let combined = output + error

            if process.terminationStatus != 0 && combined.contains("Operation not permitted") {
                // Fall back to running via Terminal which has Full Disk Access
                return try await runViaTerminal(command: chainedCommand)
            }

            return CommandResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        } else {
            // For non-privileged, just run them sequentially
            var lastResult = CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            for cmd in commands {
                lastResult = try await run(path: cmd.path, arguments: cmd.arguments, requiresPrivilege: false)
                if lastResult.exitCode != 0 {
                    return lastResult
                }
            }
            return lastResult
        }
    }

    /// Run a command via Terminal.app which has Full Disk Access.
    /// This is a fallback for when osascript's admin privileges aren't enough.
    private static func runViaTerminal(command: String) async throws -> CommandResult {
        // Create a temporary script that runs the command and captures output
        let tempDir = FileManager.default.temporaryDirectory
        let scriptId = UUID().uuidString
        let scriptPath = tempDir.appendingPathComponent("flasher_cmd_\(scriptId).sh")
        let outputPath = tempDir.appendingPathComponent("flasher_out_\(scriptId).txt")
        let exitCodePath = tempDir.appendingPathComponent("flasher_exit_\(scriptId).txt")

        let scriptContent = """
        #!/bin/bash
        \(command) > "\(outputPath.path)" 2>&1
        echo $? > "\(exitCodePath.path)"
        """

        try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        // Use osascript to run sudo in Terminal, which has Full Disk Access
        let terminalScript = """
        tell application "Terminal"
            activate
            set newTab to do script "sudo '\\(scriptPath.path)'; exit"
            repeat
                delay 0.5
                if not busy of newTab then exit repeat
            end repeat
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", terminalScript]

        try await process.runAndWait()

        // Wait for output files to appear (with timeout)
        var attempts = 0
        while !FileManager.default.fileExists(atPath: exitCodePath.path) && attempts < 120 {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            attempts += 1
        }

        // Read results
        let output = (try? Data(contentsOf: outputPath)) ?? Data()
        let exitCodeStr = (try? String(contentsOf: exitCodePath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
        let exitCode = Int32(exitCodeStr) ?? 1

        // Cleanup
        try? FileManager.default.removeItem(at: scriptPath)
        try? FileManager.default.removeItem(at: outputPath)
        try? FileManager.default.removeItem(at: exitCodePath)

        return CommandResult(
            exitCode: exitCode,
            stdout: output,
            stderr: Data()
        )
    }
}
