import Foundation
import Darwin
import WeChatScreenshotRestoreCore

public struct WeChatAppPreflightReport: Codable, Equatable {
    public let appPath: String
    public let version: String?
    public let build: String?
    public let architectures: [String]
    public let signatureValid: Bool
    public let teamIdentifier: String?
    public let hardenedRuntime: Bool
    public let runtimeAlreadyInstalled: Bool
    public let injection: [DylibInjectionReport]
    /// Indicates an exact version/build pair with end-to-end runtime evidence; this is informational.
    public let isRuntimeValidatedBuild: Bool
    public let runningProcessIDs: [Int32]
    public let quarantinePaths: [String]
    public let quarantineInspectionFailures: [String]
    public let issues: [String]

    public var canInstall: Bool {
        // A quarantine marker is preserved and shown to the user; macOS may require an
        // explicit first-launch approval after the app is re-signed. Only an unreadable
        // security state is a preflight failure.
        issues.isEmpty && signatureValid && !runtimeAlreadyInstalled && runningProcessIDs.isEmpty
    }

}

public struct WeChatRuntimeValidatedBuild: Equatable {
    public let bundleVersion: String
    public let build: String
    public let clientVersion: String

    public var displayName: String {
        if clientVersion == bundleVersion {
            return "WeChat \(clientVersion)（build \(build)）"
        }
        return "WeChat \(clientVersion)（包元数据 \(bundleVersion) / build \(build)）"
    }
}

public enum WeChatScreenshotRestorePreflight {
    public static let officialBundleIdentifier = "com.tencent.xinWeChat"
    public static let expectedTeamIdentifier = "5A4RE8SF68"
    /// Exact bundle metadata pairs with user-confirmed runtime use.
    public static let runtimeValidatedBuilds = [
        WeChatRuntimeValidatedBuild(bundleVersion: "4.1.15", build: "270135", clientVersion: "4.1.15"),
        WeChatRuntimeValidatedBuild(bundleVersion: "4.2.0", build: "270348", clientVersion: "4.2.0.12"),
    ]
    public static let hostBinaryRelativePath = "Contents/Resources/wechat.dylib"
    public static let runtimeFileName = "libWindowSharingRestore.dylib"
    public static let runtimeInstallName = "@loader_path/\(runtimeFileName)"

    public static func runtimeValidatedBuild(version: String?, build: String?) -> WeChatRuntimeValidatedBuild? {
        guard let version, let build else { return nil }
        return runtimeValidatedBuilds.first {
            $0.bundleVersion == version && $0.build == build
        }
    }

    public static func inspect(
        appURL: URL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)
    ) throws -> WeChatAppPreflightReport {
        let appURL = URL(fileURLWithPath: PathGuard.canonicalPath(appURL), isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: appURL.path),
              let info = try? readBundleInfo(at: appURL),
              let bundleID = info["CFBundleIdentifier"] as? String,
              bundleID == officialBundleIdentifier else {
            throw WeChatPreflightError.notOfficialWechat(appURL.path)
        }
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        guard let executableName = info["CFBundleExecutable"] as? String else {
            throw WeChatPreflightError.missingExecutableName
        }

        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        let targetDylibURL = appURL.appendingPathComponent(hostBinaryRelativePath)
        guard fileManager.isExecutableFile(atPath: executableURL.path),
              fileManager.isReadableFile(atPath: targetDylibURL.path) else {
            throw WeChatPreflightError.requiredBinaryMissing
        }

        let archResult = try ProcessRunner.run("/usr/bin/lipo", ["-archs", executableURL.path])
        let architectures = architectureNames(from: archResult)
        let hostArchResult = try ProcessRunner.run("/usr/bin/lipo", ["-archs", targetDylibURL.path])
        let hostArchitectures = architectureNames(from: hostArchResult)

        let verify = try ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        let details = try ProcessRunner.run("/usr/bin/codesign", ["-dv", "--verbose=4", appURL.path])
        let detailText = String(decoding: details.stdout + details.stderr, as: UTF8.self)
        let teamIdentifier = parseField("TeamIdentifier", in: detailText)
        let hardenedRuntime = parseField("flags", in: detailText)?.contains("runtime") == true
        let targetURL = appURL.appendingPathComponent(hostBinaryRelativePath)
        let runtimeURL = appURL.appendingPathComponent("Contents/Resources/\(runtimeFileName)")
        let runtimeAlreadyInstalled = fileManager.fileExists(atPath: runtimeURL.path)
        let quarantineCandidates = [
            appURL,
            executableURL,
            targetDylibURL,
        ]
        var quarantinePaths: [String] = []
        var quarantineInspectionFailures: [String] = []
        for candidate in quarantineCandidates {
            switch quarantineStatus(at: candidate) {
            case .quarantined: quarantinePaths.append(candidate.path)
            case .clear: break
            case .unknown: quarantineInspectionFailures.append(candidate.path)
            }
        }
        var injectionReports: [DylibInjectionReport] = []
        var issues: [String] = []

        if !hasRecordableVersionAndBuild(version: version, build: build) {
            issues.append("WeChat version/build metadata is missing; refusing to modify an app whose original identity cannot be recorded for rollback.")
        }
        if verify.status != 0 {
            issues.append("The installed WeChat signature does not verify; no files will be changed.")
        }
        if teamIdentifier != expectedTeamIdentifier {
            issues.append("The app's signing Team ID does not match the expected Tencent signature.")
        }
        if !architectures.contains("arm64") {
            issues.append("The WeChat app has no native Apple Silicon arm64 executable slice.")
        }
        let unsupportedArchitectures = architectures.filter { $0 != "arm64" && $0 != "x86_64" }
        if !unsupportedArchitectures.isEmpty {
            issues.append("The app contains unsupported architecture slices: \(unsupportedArchitectures.joined(separator: ", ")).")
        }
        let supportedArchitectures = architectures.compactMap(WeChatCPUArch.init(rawValue:))
        let missingHostArchitectures = architectures.filter { !hostArchitectures.contains($0) }
        if hostArchResult.status != 0 || !missingHostArchitectures.isEmpty {
            issues.append("Resources/wechat.dylib does not provide every app architecture slice.")
        }
        if !hardenedRuntime {
            issues.append("The installed WeChat Hardened Runtime state differs from the supported reference.")
        }
        if !quarantineInspectionFailures.isEmpty {
            issues.append("Could not read quarantine metadata on: \(quarantineInspectionFailures.joined(separator: ", ")). Refusing to proceed when macOS security state is unknown.")
        }

        if runtimeAlreadyInstalled {
            issues.append("A file named \(runtimeFileName) already exists in the WeChat bundle; refusing to overwrite an unknown component.")
        } else {
            do {
                let original = try Data(contentsOf: targetURL, options: .mappedIfSafe)
                let result = try MachODylibInjector.injecting(
                    runtimeInstallName,
                    architectures: supportedArchitectures,
                    into: original
                )
                injectionReports = result.reports
                if injectionReports.allSatisfy({ $0.status == .alreadyInjected }) {
                    issues.append("The WeChat binary already references the restore runtime, but the runtime file is missing.")
                }
            } catch {
                issues.append("This WeChat binary cannot accept the restore runtime safely: \(error.localizedDescription)")
            }
        }

        let runningIDs = WeChatProcessInspector.processIDs(inside: appURL)
        if !runningIDs.isEmpty {
            issues.append("WeChat is running (process IDs: \(runningIDs.map(String.init).joined(separator: ", "))); quit it normally before changing the app.")
        }

        return WeChatAppPreflightReport(
            appPath: appURL.path,
            version: version,
            build: build,
            architectures: architectures,
            signatureValid: verify.status == 0,
            teamIdentifier: teamIdentifier,
            hardenedRuntime: hardenedRuntime,
            runtimeAlreadyInstalled: runtimeAlreadyInstalled,
            injection: injectionReports,
            isRuntimeValidatedBuild: runtimeValidatedBuild(version: version, build: build) != nil,
            runningProcessIDs: runningIDs,
            quarantinePaths: quarantinePaths,
            quarantineInspectionFailures: quarantineInspectionFailures,
            issues: issues
        )
    }

    static func hasRecordableVersionAndBuild(version: String?, build: String?) -> Bool {
        guard let version, let build else { return false }
        return !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func architectureNames(from result: ProcessResult) -> [String] {
        guard result.status == 0 else { return [] }
        return String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private enum QuarantineStatus { case quarantined, clear, unknown }

    private static func quarantineStatus(at url: URL) -> QuarantineStatus {
        let names = url.path.withCString { path -> [String]? in
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size >= 0 else {
                return (errno == ENOTSUP || errno == EOPNOTSUPP) ? [] : nil
            }
            guard size > 0 else { return [] }
            var bytes = [CChar](repeating: 0, count: size)
            let actualSize = bytes.withUnsafeMutableBufferPointer { buffer in
                listxattr(path, buffer.baseAddress, size, XATTR_NOFOLLOW)
            }
            guard actualSize >= 0 else { return nil }
            return Data(bytes: bytes, count: actualSize)
                .split(separator: 0)
                .compactMap { String(data: Data($0), encoding: .utf8) }
        }
        guard let names else { return .unknown }
        return names.contains("com.apple.quarantine") ? .quarantined : .clear
    }

    private static func parseField(_ field: String, in text: String) -> String? {
        guard let range = text.range(of: "\(field)=") else { return nil }
        let value = text[range.upperBound...].prefix(while: { !$0.isWhitespace })
        return value.isEmpty || value == "not" ? nil : String(value)
    }

    private static func readBundleInfo(at appURL: URL) throws -> [String: Any] {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else {
            throw WeChatPreflightError.invalidInfoPlist
        }
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw WeChatPreflightError.invalidInfoPlist
        }
        return dictionary
    }
}

func verifyTargetStillInstallable(
    _ report: WeChatAppPreflightReport,
    expectedVersion: String,
    expectedBuild: String,
    expectedTeamIdentifier: String
) throws {
    guard report.canInstall,
          report.version == expectedVersion,
          report.build == expectedBuild,
          report.teamIdentifier == expectedTeamIdentifier else {
        throw BundleTransactionError.preflightFailed(report.issues.isEmpty
            ? ["The installed WeChat changed after backup preparation; no replacement was made."]
            : report.issues)
    }
}

public enum WeChatPreflightError: Error, LocalizedError {
    case notOfficialWechat(String)
    case missingExecutableName
    case requiredBinaryMissing
    case invalidInfoPlist

    public var errorDescription: String? {
        switch self {
        case .notOfficialWechat(let path): "No official WeChat app bundle was found at \(path)."
        case .missingExecutableName: "The WeChat bundle does not declare an executable."
        case .requiredBinaryMissing: "The WeChat executable or Resources/wechat.dylib is missing."
        case .invalidInfoPlist: "The WeChat bundle has no readable, valid Info.plist."
        }
    }
}

enum WeChatProcessInspector {
    static func processIDs(inside appURL: URL) -> [Int32] {
        let requiredBytes = max(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0), 0)
        let capacity = max(Int(requiredBytes) / MemoryLayout<pid_t>.size + 128, 512)
        var pids = [pid_t](repeating: 0, count: capacity)
        let countBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard countBytes > 0 else { return [] }
        let count = min(Int(countBytes) / MemoryLayout<pid_t>.size, pids.count)
        let root = PathGuard.canonicalPath(appURL)
        var matches: [Int32] = []
        // Four MAXPATHLEN-sized slots cover PROC_PIDPATHINFO_MAXSIZE across supported macOS SDKs.
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) where pid > 0 {
            let bytes = pathBuffer.withUnsafeMutableBufferPointer { buffer in
                proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
            }
            guard bytes > 0 else { continue }
            let processPath = String(cString: pathBuffer)
            let canonical = PathGuard.canonicalPath(URL(fileURLWithPath: processPath))
            if canonical == root || canonical.hasPrefix(root + "/") {
                matches.append(pid)
            }
        }
        return matches.sorted()
    }
}
