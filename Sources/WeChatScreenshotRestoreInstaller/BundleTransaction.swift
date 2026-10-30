import Darwin
import Foundation
import WeChatScreenshotRestoreCore

/// Atomically exchanges two sibling directories on the same volume. There is deliberately
/// no copy-and-delete fallback: if the filesystem cannot perform an atomic exchange, the
/// caller keeps the original bundle in place and reports failure.
public enum AtomicBundleSwap {
    public static func exchange(_ stagedURL: URL, with targetURL: URL) throws {
        let staged = stagedURL.standardizedFileURL
        let target = targetURL.standardizedFileURL
        guard staged.deletingLastPathComponent() == target.deletingLastPathComponent(),
              FileManager.default.fileExists(atPath: staged.path),
              FileManager.default.fileExists(atPath: target.path) else {
            throw BundleTransactionError.invalidSwapPaths
        }

        let result = staged.path.withCString { source in
            target.path.withCString { destination in
                renamex_np(source, destination, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw BundleTransactionError.atomicSwapFailed(errno)
        }
    }
}

public struct WeChatInstallationRecord: Codable, Equatable {
    public let schemaVersion: Int
    public let createdAt: Date
    public let officialAppPath: String
    public let backupAppPath: String
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let originalTeamIdentifier: String
    public let runtimeFileName: String
    public let runtimeInstallName: String

    public init(
        createdAt: Date,
        officialAppPath: String,
        backupAppPath: String,
        bundleIdentifier: String,
        version: String,
        build: String,
        originalTeamIdentifier: String,
        runtimeFileName: String = WeChatScreenshotRestorePreflight.runtimeFileName,
        runtimeInstallName: String = WeChatScreenshotRestorePreflight.runtimeInstallName
    ) {
        self.schemaVersion = 1
        self.createdAt = createdAt
        self.officialAppPath = officialAppPath
        self.backupAppPath = backupAppPath
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.originalTeamIdentifier = originalTeamIdentifier
        self.runtimeFileName = runtimeFileName
        self.runtimeInstallName = runtimeInstallName
    }
}

public struct WeChatInstallResult {
    public let record: WeChatInstallationRecord
    public let signingTeamIdentifierAfterInstall: String?
}

public enum WeChatScreenshotRestoreInstaller {
    public static let officialAppURL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)
    public static let supportURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatScreenshotRestore", isDirectory: true)
    private static let backupRootURL = supportURL.appendingPathComponent("Backups", isDirectory: true)

    /// Creates and verifies a complete app-bundle backup, patches a staged copy, verifies its
    /// ad-hoc signature, then atomically exchanges it with the installed app. No account or
    /// WeChat container data is opened, copied, or edited.
    @discardableResult
    public static func install(
        runtimeURL: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> WeChatInstallResult {
        let appURL = officialAppURL
        guard PathGuard.canonicalPath(appURL) == appURL.path else {
            throw BundleTransactionError.officialAppPathRedirected
        }
        let preflight = try WeChatScreenshotRestorePreflight.inspect(appURL: appURL)
        guard preflight.canInstall else {
            throw BundleTransactionError.preflightFailed(preflight.issues)
        }
        guard let version = preflight.version, let build = preflight.build,
              let originalTeam = preflight.teamIdentifier else {
            throw BundleTransactionError.preflightMissingMetadata
        }
        try validateRuntime(runtimeURL, requiredArchitectures: preflight.architectures)

        let appSize = try directorySize(at: appURL)
        let freeBytes = try availableBytes(onVolumeContaining: appURL)
        let requiredBytes = Int64(Double(appSize) * 2.2)
        guard freeBytes >= requiredBytes else {
            throw BundleTransactionError.insufficientDiskSpace(required: requiredBytes, available: freeBytes)
        }

        try createPrivateDirectory(backupRootURL)
        let stamp = ISO8601DateFormatter.fileSafe.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let backupDirectory = backupRootURL.appendingPathComponent("\(stamp)-\(build)", isDirectory: true)
        let backupAppURL = backupDirectory.appendingPathComponent("WeChat.app", isDirectory: true)
        let recordURL = backupDirectory.appendingPathComponent("installation.json")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var backupVerified = false
        defer { if !backupVerified { try? FileManager.default.removeItem(at: backupDirectory) } }

        let record = WeChatInstallationRecord(
            createdAt: Date(),
            officialAppPath: appURL.path,
            backupAppPath: backupAppURL.path,
            bundleIdentifier: WeChatScreenshotRestorePreflight.officialBundleIdentifier,
            version: version,
            build: build,
            originalTeamIdentifier: originalTeam
        )
        let stageURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(".WeChatScreenshotRestore-\(UUID().uuidString).app", isDirectory: true)
        var swapped = false
        defer {
            if !swapped { try? FileManager.default.removeItem(at: stageURL) }
        }

        progress("正在创建完整原版备份…")
        try copyBundle(from: appURL, to: backupAppURL)
        try verifyOriginalBackup(backupAppURL, version: version, build: build)
        backupVerified = true
        try writeRecord(record, to: recordURL)

        progress("备份已通过原始签名校验；正在准备隔离的安装副本…")
        try copyBundle(from: backupAppURL, to: stageURL)
        let stagedRuntime = stageURL.appendingPathComponent("Contents/Resources/\(record.runtimeFileName)")
        try copyFilePreservingMetadata(from: runtimeURL, to: stagedRuntime)

        let hostBinary = stageURL.appendingPathComponent(WeChatScreenshotRestorePreflight.hostBinaryRelativePath)
        let originalBinary = try Data(contentsOf: hostBinary, options: .mappedIfSafe)
        let requestedArchitectures = try targetArchitectures(of: hostBinary)
        let injected = try MachODylibInjector.injecting(record.runtimeInstallName,
                                                         architectures: requestedArchitectures,
                                                         into: originalBinary)
        guard injected.reports.allSatisfy({ $0.status == .injected }) else {
            throw BundleTransactionError.unexpectedExistingLoadCommand
        }
        try replaceFileContents(injected.data, at: hostBinary)

        progress("运行时组件已注入；正在重签安装副本并核对权限…")
        try WeChatCodeSigner.resign(appURL: stageURL, modifiedBinaries: [hostBinary, stagedRuntime])
        try validateBundleIdentity(stageURL, version: version, build: build)
        try verifyStrictSignature(stageURL)
        try verifyRuntimeLoadCommand(in: hostBinary, record: record, architectures: requestedArchitectures)

        // Bundle preparation can take long enough for the user to relaunch WeChat or for
        // the target app to change. Re-read the installed target immediately before the
        // atomic exchange; never replace a running, updated, or no-longer-vendor-signed app.
        guard PathGuard.canonicalPath(appURL) == appURL.path else {
            throw BundleTransactionError.officialAppPathRedirected
        }
        let currentPreflight = try WeChatScreenshotRestorePreflight.inspect(appURL: appURL)
        try verifyTargetStillInstallable(currentPreflight, expectedVersion: version,
                                         expectedBuild: build, expectedTeamIdentifier: originalTeam)

        progress("正在原子切换 WeChat.app…")
        try AtomicBundleSwap.exchange(stageURL, with: appURL)
        swapped = true
        do {
            try validateBundleIdentity(appURL, version: version, build: build)
            try verifyStrictSignature(appURL)
            let currentTeam = try signingTeamIdentifier(of: appURL)
            try? FileManager.default.removeItem(at: stageURL) // Previous original is also preserved in Backups.
            return WeChatInstallResult(record: record, signingTeamIdentifierAfterInstall: currentTeam)
        } catch {
            let verificationError = error.localizedDescription
            do {
                try AtomicBundleSwap.exchange(stageURL, with: appURL)
                swapped = false
                try verifyOriginalBackup(appURL, version: version, build: build)
            } catch {
                throw BundleTransactionError.recoveryExchangeFailed(
                    operation: "install verification",
                    verification: verificationError,
                    recovery: error.localizedDescription,
                    recoveryBundlePath: stageURL.path
                )
            }
            throw BundleTransactionError.postInstallVerificationFailed(verificationError)
        }
    }

    /// Restores the newest matching full bundle backup. It never overwrites an updated or
    /// unrelated WeChat build, and it refuses to act while any WeChat process is running.
    public static func rollback(progress: (String) -> Void = { _ in }) throws -> WeChatInstallationRecord {
        let appURL = officialAppURL
        guard WeChatProcessInspector.processIDs(inside: appURL).isEmpty else {
            throw BundleTransactionError.wechatStillRunning
        }
        guard let record = try latestRecord(),
              record.officialAppPath == appURL.path,
              record.bundleIdentifier == WeChatScreenshotRestorePreflight.officialBundleIdentifier,
              !record.version.isEmpty,
              !record.build.isEmpty,
              record.originalTeamIdentifier == WeChatScreenshotRestorePreflight.expectedTeamIdentifier,
              record.runtimeFileName == WeChatScreenshotRestorePreflight.runtimeFileName,
              record.runtimeInstallName == WeChatScreenshotRestorePreflight.runtimeInstallName,
              PathGuard.isSameOrDescendant(URL(fileURLWithPath: record.backupAppPath), of: backupRootURL) else {
            throw BundleTransactionError.noVerifiedBackup
        }
        let backupURL = URL(fileURLWithPath: record.backupAppPath, isDirectory: true)
        try verifyOriginalBackup(backupURL, version: record.version, build: record.build)

        let currentInfo = try bundleInfo(at: appURL)
        guard currentInfo["CFBundleIdentifier"] as? String == record.bundleIdentifier,
              currentInfo["CFBundleVersion"] as? String == record.build,
              currentInfo["CFBundleShortVersionString"] as? String == record.version,
              FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/\(record.runtimeFileName)").path) else {
            throw BundleTransactionError.currentInstallDoesNotMatchRecord
        }
        try verifyStrictSignature(appURL)
        guard try signingTeamIdentifier(of: appURL) == nil else {
            throw BundleTransactionError.currentInstallDoesNotMatchRecord
        }
        let currentBinary = appURL.appendingPathComponent(WeChatScreenshotRestorePreflight.hostBinaryRelativePath)
        let currentArchitectures = try targetArchitectures(of: currentBinary)
        try verifyRuntimeLoadCommand(in: currentBinary, record: record, architectures: currentArchitectures)

        let stageURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(".WeChatScreenshotRestore-rollback-\(UUID().uuidString).app", isDirectory: true)
        var swapped = false
        defer { if !swapped { try? FileManager.default.removeItem(at: stageURL) } }
        progress("正在从完整原版备份准备恢复副本…")
        try copyBundle(from: backupURL, to: stageURL)
        try verifyOriginalBackup(stageURL, version: record.version, build: record.build)

        progress("正在原子恢复原版 WeChat.app…")
        try AtomicBundleSwap.exchange(stageURL, with: appURL)
        swapped = true
        do {
            try verifyOriginalBackup(appURL, version: record.version, build: record.build)
            try? FileManager.default.removeItem(at: stageURL) // Retain the verified backup under Backups.
            return record
        } catch {
            let verificationError = error.localizedDescription
            do {
                try AtomicBundleSwap.exchange(stageURL, with: appURL)
                swapped = false
                try verifyStrictSignature(appURL)
            } catch {
                throw BundleTransactionError.recoveryExchangeFailed(
                    operation: "rollback verification",
                    verification: verificationError,
                    recovery: error.localizedDescription,
                    recoveryBundlePath: stageURL.path
                )
            }
            throw BundleTransactionError.postRollbackVerificationFailed(verificationError)
        }
    }

    public static func latestRecord() throws -> WeChatInstallationRecord? {
        guard FileManager.default.fileExists(atPath: backupRootURL.path) else { return nil }
        let directories = try FileManager.default.contentsOfDirectory(
            at: backupRootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        let records: [WeChatInstallationRecord] = directories.compactMap { directory in
            let url = directory.appendingPathComponent("installation.json")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(WeChatInstallationRecord.self, from: data),
                  PathGuard.isSameOrDescendant(URL(fileURLWithPath: record.backupAppPath), of: backupRootURL) else {
                return nil
            }
            return record
        }
        return records.max { $0.createdAt < $1.createdAt }
    }

    private static func validateRuntime(_ runtimeURL: URL, requiredArchitectures: [String]) throws {
        guard FileManager.default.isReadableFile(atPath: runtimeURL.path) else {
            throw BundleTransactionError.runtimeMissing(runtimeURL.path)
        }
        let runtimeArchs = try targetArchitectures(of: runtimeURL)
        let required = Set(requiredArchitectures.filter { $0 == "arm64" || $0 == "x86_64" })
        guard !required.isEmpty, required.isSubset(of: Set(runtimeArchs.map(\.rawValue))) else {
            throw BundleTransactionError.runtimeArchitectureMismatch(required: required.sorted(), actual: runtimeArchs.map(\.rawValue))
        }
        try verifyStrictSignature(runtimeURL)
    }

    private static func targetArchitectures(of binaryURL: URL) throws -> [WeChatCPUArch] {
        let result = try ProcessRunner.run("/usr/bin/lipo", ["-archs", binaryURL.path])
        guard result.status == 0 else {
            throw BundleTransactionError.architectureInspectionFailed(binaryURL.path)
        }
        let names = String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        let supported = names.compactMap(WeChatCPUArch.init(rawValue:))
        guard supported.count == names.count, !supported.isEmpty else {
            throw BundleTransactionError.unsupportedArchitecture(names)
        }
        return supported
    }

    private static func verifyOriginalBackup(_ appURL: URL, version: String, build: String) throws {
        try validateBundleIdentity(appURL, version: version, build: build)
        try verifyStrictSignature(appURL)
        guard try signingTeamIdentifier(of: appURL) == WeChatScreenshotRestorePreflight.expectedTeamIdentifier else {
            throw BundleTransactionError.backupSignatureMismatch
        }
    }

    private static func validateBundleIdentity(_ appURL: URL, version: String, build: String) throws {
        let info = try bundleInfo(at: appURL)
        guard info["CFBundleIdentifier"] as? String == WeChatScreenshotRestorePreflight.officialBundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version,
              info["CFBundleVersion"] as? String == build else {
            throw BundleTransactionError.bundleMetadataMismatch
        }
    }

    private static func verifyStrictSignature(_ appURL: URL) throws {
        let result = try ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        guard result.status == 0 else {
            throw BundleTransactionError.signatureVerificationFailed(
                String(decoding: result.stderr + result.stdout, as: UTF8.self)
            )
        }
    }

    private static func signingTeamIdentifier(of appURL: URL) throws -> String? {
        let result = try ProcessRunner.run("/usr/bin/codesign", ["-dv", "--verbose=4", appURL.path])
        let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        guard let range = text.range(of: "TeamIdentifier=") else { return nil }
        let value = text[range.upperBound...].prefix(while: { !$0.isWhitespace })
        return value == "not" ? nil : String(value)
    }

    private static func verifyRuntimeLoadCommand(in binaryURL: URL, record: WeChatInstallationRecord,
                                                 architectures: [WeChatCPUArch]) throws {
        let data = try Data(contentsOf: binaryURL, options: .mappedIfSafe)
        let result = try MachODylibInjector.injecting(record.runtimeInstallName,
                                                      architectures: architectures,
                                                      into: data)
        guard result.data == data,
              result.reports.allSatisfy({ $0.status == .alreadyInjected }) else {
            throw BundleTransactionError.loadCommandVerificationFailed
        }
    }

    private static func copyBundle(from source: URL, to destination: URL) throws {
        let result = try ProcessRunner.run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", "--qtn", source.path, destination.path])
        guard result.status == 0 else {
            throw BundleTransactionError.copyFailed(String(decoding: result.stderr + result.stdout, as: UTF8.self))
        }
    }

    private static func copyFilePreservingMetadata(from source: URL, to destination: URL) throws {
        let result = try ProcessRunner.run("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", "--qtn", source.path, destination.path])
        guard result.status == 0 else {
            throw BundleTransactionError.copyFailed(String(decoding: result.stderr + result.stdout, as: UTF8.self))
        }
    }

    private static func replaceFileContents(_ data: Data, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func writeRecord(_ record: WeChatInstallationRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    private static func bundleInfo(at url: URL) throws -> [String: Any] {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw BundleTransactionError.bundleMetadataMismatch
        }
        return info
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func directorySize(at root: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [], errorHandler: { _, _ in false }
        ) else { throw BundleTransactionError.cannotEnumerateBundle }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func availableBytes(onVolumeContaining url: URL) throws -> Int64 {
        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else {
            throw BundleTransactionError.cannotCheckDiskSpace
        }
        return available
    }
}

public enum BundleTransactionError: Error, LocalizedError {
    case invalidSwapPaths
    case atomicSwapFailed(Int32)
    case officialAppPathRedirected
    case preflightFailed([String])
    case preflightMissingMetadata
    case insufficientDiskSpace(required: Int64, available: Int64)
    case runtimeMissing(String)
    case runtimeArchitectureMismatch(required: [String], actual: [String])
    case architectureInspectionFailed(String)
    case unsupportedArchitecture([String])
    case backupSignatureMismatch
    case bundleMetadataMismatch
    case signatureVerificationFailed(String)
    case unexpectedExistingLoadCommand
    case loadCommandVerificationFailed
    case copyFailed(String)
    case cannotEnumerateBundle
    case cannotCheckDiskSpace
    case wechatStillRunning
    case noVerifiedBackup
    case currentInstallDoesNotMatchRecord
    case postInstallVerificationFailed(String)
    case postRollbackVerificationFailed(String)
    case recoveryExchangeFailed(operation: String, verification: String, recovery: String, recoveryBundlePath: String)

    public var errorDescription: String? {
        switch self {
        case .invalidSwapPaths: "The staged bundle must be a sibling of the installed bundle, and both must exist."
        case .atomicSwapFailed(let code): "The filesystem refused an atomic app-bundle exchange (errno \(code)); the installed app was not replaced."
        case .officialAppPathRedirected: "The standard WeChat app path resolves elsewhere; refusing to modify it."
        case .preflightFailed(let issues): "WeChat is not safe to install into: \(issues.joined(separator: " "))"
        case .preflightMissingMetadata: "Preflight did not return the WeChat version, build, and signing identity needed to record a safe rollback."
        case .insufficientDiskSpace(let required, let available): "Not enough free space for a full backup and staging copy (need about \(required) bytes; have \(available))."
        case .runtimeMissing(let path): "The signed restore runtime is missing at \(path)."
        case .runtimeArchitectureMismatch(let required, let actual): "The runtime architectures (\(actual.joined(separator: ", "))) do not cover WeChat (\(required.joined(separator: ", ")))."
        case .architectureInspectionFailed(let path): "Could not read the Mach-O architecture list for \(path)."
        case .unsupportedArchitecture(let names): "Unsupported WeChat architecture slice: \(names.joined(separator: ", "))."
        case .backupSignatureMismatch: "The backup does not retain Tencent's original verified signature."
        case .bundleMetadataMismatch: "The WeChat bundle ID, version, or build changed during the operation."
        case .signatureVerificationFailed(let detail): "Strict code-signature verification failed: \(detail)"
        case .unexpectedExistingLoadCommand: "The backup already contains the restore load command; refusing to stack another patch."
        case .loadCommandVerificationFailed: "The staged WeChat binary did not retain the expected runtime load command."
        case .copyFailed(let detail): "Could not copy the app bundle: \(detail)"
        case .cannotEnumerateBundle: "Could not estimate the app bundle size before preparing the backup."
        case .cannotCheckDiskSpace: "Could not confirm free disk space; no files were changed."
        case .wechatStillRunning: "Quit WeChat normally before restoring the original app."
        case .noVerifiedBackup: "No valid restore record and complete original WeChat backup were found."
        case .currentInstallDoesNotMatchRecord: "The installed app is not the patched build associated with this backup; refusing to overwrite it."
        case .postInstallVerificationFailed(let detail): "The replacement did not verify and was atomically rolled back: \(detail)"
        case .postRollbackVerificationFailed(let detail): "The restored app did not verify and the previous app was put back: \(detail)"
        case .recoveryExchangeFailed(let operation, let verification, let recovery, let path):
            "The \(operation) failed verification (\(verification)), and automatic recovery also failed (\(recovery)). Preserve the staged bundle at \(path) and the verified full backup; do not launch WeChat until recovery is complete."
        }
    }
}

private extension ISO8601DateFormatter {
    static let fileSafe: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
