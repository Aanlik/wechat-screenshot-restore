import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsrestore-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let stdoutURL = tempRoot.appendingPathComponent("stdout")
        let stderrURL = tempRoot.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
              FileManager.default.createFile(atPath: stderrURL.path, contents: nil) else {
            throw ProcessRunnerError.cannotCreateCaptureFiles
        }
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(executable, error.localizedDescription)
        }
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: stdoutURL),
            stderr: try Data(contentsOf: stderrURL)
        )
    }
}

enum ProcessRunnerError: Error, LocalizedError {
    case cannotCreateCaptureFiles
    case launchFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateCaptureFiles: "Could not prepare a private temporary process-capture directory."
        case .launchFailed(let executable, let reason): "Could not run \(executable): \(reason)"
        }
    }
}
