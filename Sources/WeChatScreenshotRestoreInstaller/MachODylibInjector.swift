import Foundation

public enum WeChatCPUArch: String, CaseIterable, Codable {
    case arm64
    case x86_64

    fileprivate var cpuType: Int32 {
        switch self {
        case .arm64: 0x0100000c
        case .x86_64: 0x01000007
        }
    }
}

public struct DylibInjectionReport: Codable, Equatable {
    public enum Status: String, Codable { case injected, alreadyInjected }
    public let architecture: WeChatCPUArch
    public let installName: String
    public let loadCommandOffset: UInt64
    public let remainingHeaderPadding: UInt64
    public let status: Status
}

public enum MachOInjectionError: Error, LocalizedError {
    case unsupportedFile
    case malformed(String)
    case missingArchitecture([String])
    case insufficientHeaderPadding(architecture: String, needed: Int, available: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            "The target is not a supported 64-bit Mach-O file."
        case .malformed(let detail):
            "The Mach-O load commands are malformed: \(detail)"
        case .missingArchitecture(let architectures):
            "The target has no executable slice for \(architectures.joined(separator: ", "))."
        case .insufficientHeaderPadding(let architecture, let needed, let available):
            "The \(architecture) header has only \(available) bytes of padding; \(needed) are required."
        }
    }
}

/// Adds one ordinary LC_LOAD_DYLIB command to each requested 64-bit slice. The edit is made
/// only inside unused Mach-O header padding; file offsets and section contents are not moved.
/// This parser is deliberately narrow: it rejects unknown file layouts rather than guessing.
public enum MachODylibInjector {
    private static let machO64LittleEndian: UInt32 = 0xfeedfacf
    private static let fat32BigEndian: UInt32 = 0xcafebabe
    private static let fat64BigEndian: UInt32 = 0xcafebabf
    private static let dylibLoadCommand: UInt32 = 0x0c
    private static let segment64Command: UInt32 = 0x19
    private static let machHeader64Size = 32
    private static let segment64MinimumSize = 72
    private static let section64Size = 80
    private static let dylibCommandFixedSize = 24

    private struct Slice {
        let architecture: WeChatCPUArch
        let start: Int
        let size: Int
    }

    public static func injecting(
        _ installName: String,
        architectures requestedArchitectures: [WeChatCPUArch],
        into original: Data
    ) throws -> (data: Data, reports: [DylibInjectionReport]) {
        guard !installName.isEmpty,
              !installName.utf8.contains(0),
              !requestedArchitectures.isEmpty else {
            throw MachOInjectionError.malformed("empty install name or architecture list")
        }

        let requested = Set(requestedArchitectures)
        guard requested.count == requestedArchitectures.count else {
            throw MachOInjectionError.malformed("duplicate architecture request")
        }

        let slices = try findRequestedSlices(in: original, requested: requested)
        var found = Set<WeChatCPUArch>()
        var patched = original
        var reports: [DylibInjectionReport] = []
        for slice in slices {
            guard found.insert(slice.architecture).inserted else {
                throw MachOInjectionError.malformed("multiple slices match \(slice.architecture.rawValue)")
            }
            reports.append(try patchSlice(
                &patched,
                slice: slice,
                installName: installName
            ))
        }

        let missing = requestedArchitectures.filter { !found.contains($0) }
        guard missing.isEmpty else {
            throw MachOInjectionError.missingArchitecture(missing.map(\.rawValue))
        }
        return (patched, reports)
    }

    private static func findRequestedSlices(in data: Data, requested: Set<WeChatCPUArch>) throws -> [Slice] {
        let magic = try data.readBigEndian32(at: 0)
        if magic == fat32BigEndian || magic == fat64BigEndian {
            let count = Int(try data.readBigEndian32(at: 4))
            guard count > 0, count <= 128 else {
                throw MachOInjectionError.malformed("invalid universal-binary slice count")
            }
            let is64 = magic == fat64BigEndian
            let entrySize = is64 ? 32 : 20
            try data.checkRange(8, count * entrySize)
            var slices: [Slice] = []

            for index in 0..<count {
                let entry = 8 + index * entrySize
                let cpu = Int32(bitPattern: try data.readBigEndian32(at: entry))
                guard let architecture = requested.first(where: { $0.cpuType == cpu }) else { continue }
                let offsetValue = is64
                    ? try data.readBigEndian64(at: entry + 8)
                    : UInt64(try data.readBigEndian32(at: entry + 8))
                let sizeValue = is64
                    ? try data.readBigEndian64(at: entry + 16)
                    : UInt64(try data.readBigEndian32(at: entry + 12))
                guard offsetValue <= UInt64(Int.max), sizeValue <= UInt64(Int.max) else {
                    throw MachOInjectionError.malformed("universal-binary slice range overflow")
                }
                let start = Int(offsetValue)
                let size = Int(sizeValue)
                try data.checkRange(start, size)
                slices.append(Slice(architecture: architecture, start: start, size: size))
            }
            return slices
        }

        guard try data.readLittleEndian32(at: 0) == machO64LittleEndian else {
            throw MachOInjectionError.unsupportedFile
        }
        try data.checkRange(0, machHeader64Size)
        let cpu = Int32(bitPattern: try data.readLittleEndian32(at: 4))
        guard let architecture = requested.first(where: { $0.cpuType == cpu }) else {
            throw MachOInjectionError.missingArchitecture(requested.map(\.rawValue).sorted())
        }
        return [Slice(architecture: architecture, start: 0, size: data.count)]
    }

    private static func patchSlice(
        _ data: inout Data,
        slice: Slice,
        installName: String
    ) throws -> DylibInjectionReport {
        let start = slice.start
        let limit = start + slice.size
        try data.checkRange(start, machHeader64Size)
        guard try data.readLittleEndian32(at: start) == machO64LittleEndian else {
            throw MachOInjectionError.unsupportedFile
        }
        guard Int32(bitPattern: try data.readLittleEndian32(at: start + 4)) == slice.architecture.cpuType else {
            throw MachOInjectionError.malformed("universal-binary architecture table does not match its slice")
        }

        let commandCount = Int(try data.readLittleEndian32(at: start + 16))
        let commandBytes = Int(try data.readLittleEndian32(at: start + 20))
        guard commandCount <= 100_000 else {
            throw MachOInjectionError.malformed("unreasonable load-command count")
        }
        let commandStart = start + machHeader64Size
        guard commandBytes <= limit - commandStart else {
            throw MachOInjectionError.malformed("load-command table exceeds the architecture slice")
        }
        let commandEnd = commandStart + commandBytes
        var cursor = commandStart
        var firstFileDataOffset: Int?
        var existingCommandOffset: Int?

        for _ in 0..<commandCount {
            guard cursor <= commandEnd - 8 else {
                throw MachOInjectionError.malformed("load command header is truncated")
            }
            let command = try data.readLittleEndian32(at: cursor)
            let commandSize = Int(try data.readLittleEndian32(at: cursor + 4))
            guard commandSize >= 8, commandSize <= commandEnd - cursor else {
                throw MachOInjectionError.malformed("invalid load-command size")
            }

            if command == dylibLoadCommand {
                guard commandSize >= dylibCommandFixedSize else {
                    throw MachOInjectionError.malformed("short LC_LOAD_DYLIB")
                }
                let pathOffset = Int(try data.readLittleEndian32(at: cursor + 8))
                guard pathOffset >= dylibCommandFixedSize, pathOffset < commandSize else {
                    throw MachOInjectionError.malformed("invalid LC_LOAD_DYLIB name offset")
                }
                let pathStart = cursor + pathOffset
                let pathEndLimit = cursor + commandSize
                guard let terminator = (pathStart..<pathEndLimit).first(where: { data[$0] == 0 }) else {
                    throw MachOInjectionError.malformed("unterminated LC_LOAD_DYLIB name")
                }
                if String(data: data[pathStart..<terminator], encoding: .utf8) == installName {
                    existingCommandOffset = cursor
                }
            } else if command == segment64Command {
                guard commandSize >= segment64MinimumSize else {
                    throw MachOInjectionError.malformed("short LC_SEGMENT_64")
                }
                let sectionCount = Int(try data.readLittleEndian32(at: cursor + 64))
                guard sectionCount <= (commandSize - segment64MinimumSize) / section64Size else {
                    throw MachOInjectionError.malformed("LC_SEGMENT_64 section table exceeds command")
                }

                let fileOffset = try data.readLittleEndian64(at: cursor + 40)
                let fileSize = try data.readLittleEndian64(at: cursor + 48)
                if fileOffset > 0, fileSize > 0 {
                    firstFileDataOffset = min(
                        firstFileDataOffset ?? Int.max,
                        try checkedFileOffset(fileOffset, fileSize: fileSize, slice: slice)
                    )
                }
                if sectionCount > 0 {
                    for sectionIndex in 0..<sectionCount {
                        let section = cursor + segment64MinimumSize + sectionIndex * section64Size
                        let sectionOffset = Int(try data.readLittleEndian32(at: section + 48))
                        if sectionOffset > 0 {
                            let absoluteOffset = start.addingReportingOverflow(sectionOffset)
                            guard !absoluteOffset.overflow, absoluteOffset.partialValue < limit else {
                                throw MachOInjectionError.malformed("section data offset exceeds its architecture slice")
                            }
                            firstFileDataOffset = min(firstFileDataOffset ?? Int.max, absoluteOffset.partialValue)
                        }
                    }
                }
            }
            cursor += commandSize
        }

        guard cursor == commandEnd else {
            throw MachOInjectionError.malformed("ncmds and sizeofcmds disagree")
        }
        guard let firstFileDataOffset, firstFileDataOffset >= commandEnd else {
            throw MachOInjectionError.malformed("unable to locate unused Mach-O header padding")
        }

        let available = firstFileDataOffset - commandEnd
        if let existingCommandOffset {
            return DylibInjectionReport(
                architecture: slice.architecture,
                installName: installName,
                loadCommandOffset: UInt64(existingCommandOffset),
                remainingHeaderPadding: UInt64(available),
                status: .alreadyInjected
            )
        }

        let newCommand = try makeDylibCommand(installName)
        guard newCommand.count <= available else {
            throw MachOInjectionError.insufficientHeaderPadding(
                architecture: slice.architecture.rawValue,
                needed: newCommand.count,
                available: available
            )
        }
        guard commandCount < Int(UInt32.max), commandBytes <= Int(UInt32.max) - newCommand.count else {
            throw MachOInjectionError.malformed("load-command table size overflow")
        }

        data.replaceSubrange(commandEnd..<(commandEnd + newCommand.count), with: newCommand)
        try data.writeLittleEndian32(UInt32(commandCount + 1), at: start + 16)
        try data.writeLittleEndian32(UInt32(commandBytes + newCommand.count), at: start + 20)
        return DylibInjectionReport(
            architecture: slice.architecture,
            installName: installName,
            loadCommandOffset: UInt64(commandEnd),
            remainingHeaderPadding: UInt64(available - newCommand.count),
            status: .injected
        )
    }

    private static func checkedFileOffset(_ offset: UInt64, fileSize: UInt64, slice: Slice) throws -> Int {
        guard offset <= UInt64(Int.max), fileSize <= UInt64(Int.max) else {
            throw MachOInjectionError.malformed("segment file offset overflow")
        }
        let end = offset.addingReportingOverflow(fileSize)
        guard !end.overflow, end.partialValue <= UInt64(slice.size) else {
            throw MachOInjectionError.malformed("segment file range exceeds its architecture slice")
        }
        let absolute = slice.start.addingReportingOverflow(Int(offset))
        guard !absolute.overflow, absolute.partialValue < slice.start + slice.size else {
            throw MachOInjectionError.malformed("segment file offset exceeds its architecture slice")
        }
        return absolute.partialValue
    }

    private static func makeDylibCommand(_ path: String) throws -> Data {
        let name = Array(path.utf8) + [0]
        let unpaddedSize = dylibCommandFixedSize.addingReportingOverflow(name.count)
        guard !unpaddedSize.overflow else {
            throw MachOInjectionError.malformed("install name is too long")
        }
        let aligned = unpaddedSize.partialValue.addingReportingOverflow(7)
        guard !aligned.overflow else {
            throw MachOInjectionError.malformed("install name is too long")
        }
        let commandSize = aligned.partialValue & ~7
        guard commandSize <= Int(UInt32.max) else {
            throw MachOInjectionError.malformed("install name is too long")
        }
        var command = Data(repeating: 0, count: commandSize)
        try command.writeLittleEndian32(dylibLoadCommand, at: 0)
        try command.writeLittleEndian32(UInt32(commandSize), at: 4)
        try command.writeLittleEndian32(UInt32(dylibCommandFixedSize), at: 8)
        try command.writeLittleEndian32(2, at: 12) // Current version: 0, compatibility version: 2.
        command.replaceSubrange(dylibCommandFixedSize..<(dylibCommandFixedSize + name.count), with: name)
        return command
    }
}

private extension Data {
    func checkRange(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw MachOInjectionError.malformed("read outside file bounds")
        }
    }

    func readLittleEndian32(at offset: Int) throws -> UInt32 {
        try checkRange(offset, 4)
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func readBigEndian32(at offset: Int) throws -> UInt32 {
        try checkRange(offset, 4)
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    func readLittleEndian64(at offset: Int) throws -> UInt64 {
        try checkRange(offset, 8)
        return (0..<8).reduce(UInt64(0)) { value, byte in
            value | (UInt64(self[offset + byte]) << (byte * 8))
        }
    }

    func readBigEndian64(at offset: Int) throws -> UInt64 {
        try checkRange(offset, 8)
        return (0..<8).reduce(UInt64(0)) { value, byte in
            (value << 8) | UInt64(self[offset + byte])
        }
    }

    mutating func writeLittleEndian32(_ value: UInt32, at offset: Int) throws {
        try checkRange(offset, 4)
        for byte in 0..<4 {
            self[offset + byte] = UInt8((value >> (byte * 8)) & 0xff)
        }
    }
}
