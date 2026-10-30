import Foundation

// Preserve every readable original entitlement and re-sign only changed libraries plus
// the enclosing app; fail closed if the main app's entitlement snapshot is absent.
public enum WeChatCodeSigner {
    /// Re-signs only files changed by this utility and the enclosing app bundle. Nested
    /// frameworks and helper apps retain their original signatures and identities.
    public static func resign(appURL: URL, modifiedBinaries: [URL]) throws {
        let originalMainEntitlements = try inspectSignedCode(at: appURL)
        let expectedMainEntitlements = try augmentedEntitlements(originalMainEntitlements, forMainApplication: true)

        for binary in uniqueURLs(modifiedBinaries) {
            let originalEntitlements = try inspectSignedCode(at: binary)
            try signMachO(at: binary, entitlements: originalEntitlements, preserveMetadata: true)
            try verifySignature(at: binary)
            guard entitlementsEqual(originalEntitlements, try inspectSignedCode(at: binary)) else {
                throw CodeSigningError.entitlementsMismatch([binary.path])
            }
        }

        try runCodesign(at: appURL, entitlements: expectedMainEntitlements, preserveMetadata: true)
        try verifySignature(at: appURL, deep: true)

        guard entitlementsEqual(expectedMainEntitlements, try inspectSignedCode(at: appURL)) else {
            throw CodeSigningError.entitlementsMismatch([appURL.path])
        }
    }
}

func augmentedEntitlements(_ original: Data?, forMainApplication: Bool) throws -> Data? {
    guard forMainApplication else { return original }
    guard let original else { throw CodeSigningError.requiredMainEntitlementsMissing }
    let dictionary: [String: Any]
    do {
        guard let parsed = try PropertyListSerialization.propertyList(from: original, options: [], format: nil) as? [String: Any],
              !parsed.isEmpty else {
            throw CodeSigningError.malformedEntitlements("The original WeChat app entitlements are not a non-empty property list.")
        }
        var augmented = parsed
        augmented["com.apple.security.cs.disable-library-validation"] = true
        dictionary = augmented
    } catch let error as CodeSigningError {
        throw error
    } catch {
        throw CodeSigningError.malformedEntitlements("Could not parse the original WeChat app entitlements: \(error.localizedDescription)")
    }
    do {
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    } catch {
        throw CodeSigningError.malformedEntitlements("Could not serialize the preserved WeChat app entitlements: \(error.localizedDescription)")
    }
}

private func signMachO(at url: URL, entitlements: Data?, preserveMetadata: Bool) throws {
    try runCodesign(at: url, entitlements: entitlements, preserveMetadata: preserveMetadata)
}

private func runCodesign(at url: URL, entitlements: Data?, preserveMetadata: Bool) throws {
    let result = try withEntitlementsFile(entitlements) { entitlementsURL in
        try ProcessRunner.run(
            "/usr/bin/codesign",
            codesignArguments(at: url, entitlementsURL: entitlementsURL, preserveMetadata: preserveMetadata)
        )
    }
    guard result.status == 0 else {
        throw CodeSigningError.commandFailed("codesign", String(decoding: result.stderr + result.stdout, as: UTF8.self))
    }
}

private func verifySignature(at url: URL, deep: Bool = false) throws {
    var arguments = ["--verify", "--strict"]
    if deep { arguments.append("--deep") }
    arguments.append(url.path)
    let result = try ProcessRunner.run("/usr/bin/codesign", arguments)
    guard result.status == 0 else {
        throw CodeSigningError.verificationFailed(String(decoding: result.stderr + result.stdout, as: UTF8.self))
    }
}

private func codesignArguments(at url: URL, entitlementsURL: URL?, preserveMetadata: Bool) -> [String] {
    var arguments = ["--force"]
    if preserveMetadata { arguments.append("--preserve-metadata=identifier,flags,runtime") }
    arguments.append(contentsOf: ["--sign", "-"])
    if let entitlementsURL {
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) {
            arguments.append("--force-library-entitlements")
        }
        arguments.append(contentsOf: ["--entitlements", entitlementsURL.path])
    }
    arguments.append(url.path)
    return arguments
}

private func inspectSignedCode(at url: URL) throws -> Data? {
    let result = try ProcessRunner.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", url.path])
    guard result.status == 0 else {
        throw CodeSigningError.entitlementsInspectionFailed(
            url.path,
            String(decoding: result.stderr + result.stdout, as: UTF8.self)
        )
    }
    guard !result.stdout.isEmpty else { return nil }
    do {
        guard let dictionary = try PropertyListSerialization.propertyList(from: result.stdout, options: [], format: nil) as? [String: Any],
              !dictionary.isEmpty else {
            throw CodeSigningError.malformedEntitlements("codesign returned an empty or non-dictionary entitlement list for \(url.path).")
        }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    } catch let error as CodeSigningError {
        throw error
    } catch {
        throw CodeSigningError.malformedEntitlements("Could not parse entitlements for \(url.path): \(error.localizedDescription)")
    }
}

private func withEntitlementsFile<T>(_ data: Data?, body: (URL?) throws -> T) throws -> T {
    guard let data else { return try body(nil) }
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wsrestore-entitlements-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let url = tempDirectory.appendingPathComponent("entitlements.plist")
    try data.write(to: url, options: .atomic)
    return try body(url)
}

private func entitlementsEqual(_ left: Data?, _ right: Data?) -> Bool {
    switch (left, right) {
    case (nil, nil): return true
    case let (left?, right?):
        guard let a = try? PropertyListSerialization.propertyList(from: left, options: [], format: nil) as? [String: Any],
              let b = try? PropertyListSerialization.propertyList(from: right, options: [], format: nil) as? [String: Any] else { return false }
        return NSDictionary(dictionary: a).isEqual(to: b)
    default: return false
    }
}

private func uniqueURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
}

public enum CodeSigningError: Error, LocalizedError {
    case commandFailed(String, String)
    case verificationFailed(String)
    case entitlementsInspectionFailed(String, String)
    case requiredMainEntitlementsMissing
    case malformedEntitlements(String)
    case entitlementsMismatch([String])

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let detail): "\(command) failed: \(detail)"
        case .verificationFailed(let detail): "The re-signed app did not pass strict signature verification: \(detail)"
        case .entitlementsInspectionFailed(let path, let detail): "Could not inspect signed entitlements for \(path): \(detail)"
        case .requiredMainEntitlementsMissing: "The original WeChat app has no readable entitlements; refusing to re-sign without them."
        case .malformedEntitlements(let detail): "The WeChat entitlements could not be safely preserved: \(detail)"
        case .entitlementsMismatch(let paths): "The re-signed app did not contain the expected entitlements: \(paths.joined(separator: ", "))"
        }
    }
}
