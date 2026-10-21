import Foundation

/// Little-endian cursor over a byte buffer, used by the A2S and A3SBP parsers.
struct ByteReader: Sendable {
    enum ReaderError: Error, LocalizedError {
        case underflow(needed: Int, available: Int)
        case unterminatedString

        var errorDescription: String? {
            switch self {
            case let .underflow(needed, available):
                "Truncated packet: needed \(needed) bytes, \(available) remaining."
            case .unterminatedString:
                "Truncated packet: string is missing its null terminator."
            }
        }
    }

    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - position }
    var isAtEnd: Bool { remaining <= 0 }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= count else {
            throw ReaderError.underflow(needed: count, available: remaining)
        }
        let slice = bytes[position..<(position + count)]
        position += count
        return slice
    }

    mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw ReaderError.underflow(needed: 1, available: remaining) }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func int8() throws -> Int8 { Int8(bitPattern: try byte()) }

    mutating func uint16() throws -> UInt16 {
        let slice = try take(2)
        return slice.enumerated().reduce(UInt16(0)) { $0 | UInt16($1.element) << (8 * $1.offset) }
    }

    mutating func uint32() throws -> UInt32 {
        let slice = try take(4)
        return slice.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func uint64() throws -> UInt64 {
        let slice = try take(8)
        return slice.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }

    mutating func float32() throws -> Float {
        Float(bitPattern: try uint32())
    }

    /// Null-terminated string. Server-supplied text is frequently not valid UTF-8, so it is
    /// decoded leniently — a mangled name is better than a dropped server.
    mutating func cString() throws -> String {
        var scanned = position
        while scanned < bytes.count, bytes[scanned] != 0 { scanned += 1 }
        guard scanned < bytes.count else { throw ReaderError.unterminatedString }
        let slice = bytes[position..<scanned]
        position = scanned + 1
        return String(decoding: slice, as: UTF8.self)
    }

    /// Raw bytes up to (and consuming) the next null terminator.
    mutating func cStringBytes() throws -> ArraySlice<UInt8> {
        var scanned = position
        while scanned < bytes.count, bytes[scanned] != 0 { scanned += 1 }
        guard scanned < bytes.count else { throw ReaderError.unterminatedString }
        let slice = bytes[position..<scanned]
        position = scanned + 1
        return slice
    }

    mutating func string(length: Int) throws -> String {
        String(decoding: try take(length), as: UTF8.self)
    }

    mutating func data(length: Int) throws -> Data {
        Data(try take(length))
    }

    mutating func skip(_ count: Int) throws { _ = try take(count) }
}

/// Little-endian byte writer for building query packets.
struct ByteWriter: Sendable {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    mutating func byte(_ value: UInt8) { bytes.append(value) }
    mutating func uint16(_ value: UInt16) {
        bytes.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    mutating func uint32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func raw(_ value: [UInt8]) { bytes.append(contentsOf: value) }
    mutating func raw(_ value: Data) { bytes.append(contentsOf: value) }

    mutating func cString(_ value: String) {
        bytes.append(contentsOf: Array(value.utf8))
        bytes.append(0)
    }
}
