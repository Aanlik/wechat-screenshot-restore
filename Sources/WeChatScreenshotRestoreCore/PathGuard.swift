import Foundation

public enum PathGuard {
    public static func canonicalPath(_ url: URL) -> String {
        let fileManager = FileManager.default
        let standardized = url.standardizedFileURL
        var existingPrefix = standardized
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existingPrefix.path), existingPrefix.path != "/" {
            missingComponents.insert(existingPrefix.lastPathComponent, at: 0)
            existingPrefix.deleteLastPathComponent()
        }
        var resolved = existingPrefix.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    public static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidatePath = canonicalPath(candidate)
        let rootPath = canonicalPath(root)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    public static func isInstalledWeChatPath(_ candidate: URL) -> Bool {
        let officialPath = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)
        return isSameOrDescendant(candidate, of: officialPath)
    }
}
