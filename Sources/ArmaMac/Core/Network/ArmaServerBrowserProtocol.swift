import Foundation

/// Decoder for the Arma 3 Server Browser Protocol v3, which Arma tunnels through
/// `A2S_RULES`.
///
/// The rules response is not a normal key/value map: keys are two bytes
/// `[pageIndex, pageCount]` and the values are 124-byte fragments of one binary message.
/// Before transmission the message has three byte values escaped, because Steam's relay
/// cannot carry them:
///
/// * `0x01 0x01` → `0x01`
/// * `0x01 0x02` → `0x00`
/// * `0x01 0x03` → `0xFF`
///
/// Reassembled, the message is: version, flags, DLC bitmask, difficulty, DLC hashes,
/// mods, signatures.
///
/// Reference: https://community.bistudio.com/wiki/Arma_3:_ServerBrowserProtocol3
enum ArmaServerBrowserProtocol {
    struct Payload: Sendable {
        var version: UInt8 = 0
        var flags: UInt8 = 0
        var difficulty: Difficulty?
        var dlcs: [ServerDLC] = []
        var mods: [ServerMod] = []
        var signatures: [String] = []
        /// Rules that were not part of the paged sub-protocol, kept for diagnostics.
        var extraRules: [String: String] = [:]
    }

    struct Difficulty: Sendable, Hashable {
        var level: UInt8
        var aiLevel: UInt8
        var advancedFlightModel: Bool
        var thirdPerson: Bool
        var crosshair: Bool

        var levelName: String {
            switch level {
            case 0: "Recruit"
            case 1: "Regular"
            case 2: "Veteran"
            case 3: "Custom"
            default: "Unknown"
            }
        }
    }

    enum DecodeError: Error, LocalizedError {
        case unsupportedVersion(UInt8)
        case truncated(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(version):
                "Unsupported server browser protocol version \(version)."
            case let .truncated(section):
                "Server browser data ended early while reading \(section)."
            }
        }
    }

    /// Arma 3 DLC bitmask, low bit first.
    static let dlcTable: [(mask: UInt16, appID: UInt64, name: String)] = [
        (0x0001, 288_520, "Karts"),
        (0x0002, 332_350, "Marksmen"),
        (0x0004, 304_380, "Helicopters"),
        (0x0008, 275_700, "Zeus"),
        (0x0010, 395_180, "Apex"),
        (0x0020, 601_670, "Jets"),
        (0x0040, 571_710, "Laws of War"),
        (0x0080, 639_600, "Malden"),
        (0x0100, 744_950, "Tac-Ops Mission Pack"),
        (0x0200, 798_390, "Tanks"),
        (0x0400, 1_021_790, "Contact"),
        (0x0800, 1_021_790, "Contact (Platform)"),
        (0x1000, 1_325_500, "Art of War"),
    ]

    /// Creator DLC arrive in the mod block with a marker length instead of a real id length.
    static let creatorDLCNames: [UInt64: String] = [
        1_042_220: "Global Mobilization — Cold War Germany",
        1_175_380: "Spearhead 1944",
        1_227_700: "S.O.G. Prairie Fire",
        1_294_440: "CSLA Iron Curtain",
        1_681_170: "Western Sahara",
        2_647_760: "Reaction Forces",
        2_647_830: "Expeditionary Forces",
    ]

    /// Folder each Creator DLC installs into. Arma loads them by folder name — `-mod=vn` —
    /// so this, not the display name, is what maps a server's requirement to what is on disk.
    static let creatorDLCFolders: [UInt64: String] = [
        1_042_220: "gm",
        1_175_380: "spe",
        1_227_700: "vn",
        1_294_440: "csla",
        1_681_170: "ws",
        2_647_760: "rf",
        2_647_830: "ef",
    ]

    /// Reverses the escape table applied by the server.
    static func unescape(_ bytes: [UInt8], into output: inout [UInt8]) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x01, index + 1 < bytes.count {
                switch bytes[index + 1] {
                case 0x01: output.append(0x01); index += 2
                case 0x02: output.append(0x00); index += 2
                case 0x03: output.append(0xFF); index += 2
                default: output.append(byte); index += 1
                }
            } else {
                output.append(byte)
                index += 1
            }
        }
    }

    /// Joins the paged rule values back into the binary message and decodes it.
    static func decode(rules: A2SRules) throws -> Payload {
        var stream: [UInt8] = []
        stream.reserveCapacity(rules.pairs.count * 128)
        var extras: [String: String] = [:]

        for pair in rules.pairs {
            // Paged entries have a 2-byte key of [index, count]; anything else is a plain rule.
            if pair.key.count == 2, pair.key[0] <= pair.key[1] {
                unescape(pair.value, into: &stream)
            } else if !pair.key.isEmpty {
                extras[String(decoding: pair.key, as: UTF8.self)] =
                    String(decoding: pair.value, as: UTF8.self)
            }
        }

        var payload = try decodeMessage(stream)
        payload.extraRules = extras
        return payload
    }

    static func decodeMessage(_ bytes: [UInt8]) throws -> Payload {
        var payload = Payload()
        guard !bytes.isEmpty else { return payload }
        var reader = ByteReader(bytes)

        payload.version = try reader.byte()
        guard payload.version == 2 || payload.version == 3 else {
            throw DecodeError.unsupportedVersion(payload.version)
        }

        payload.flags = try reader.byte()
        let dlcMask = try reader.uint16()

        // Difficulty occupies two bytes in the Arma 3 (v3) layout.
        if payload.version == 3 {
            let first = try reader.byte()
            let second = try reader.byte()
            if first != 0 {
                payload.difficulty = Difficulty(
                    level: first & 0b0000_0111,
                    aiLevel: (first >> 3) & 0b0000_0111,
                    // Bit 6 is inverted: set means the standard flight model.
                    advancedFlightModel: first & (1 << 6) == 0,
                    thirdPerson: first & (1 << 7) != 0,
                    crosshair: second & 0x01 != 0
                )
            }
        }

        if dlcMask != 0 {
            payload.dlcs = try readDLCs(mask: dlcMask, reader: &reader)
        }
        try readMods(reader: &reader, into: &payload)
        payload.signatures = try readSignatures(reader: &reader)
        return payload
    }

    private static func readDLCs(mask: UInt16, reader: inout ByteReader) throws -> [ServerDLC] {
        var entries: [ServerDLC] = []
        var unmatched = mask
        for row in dlcTable where mask & row.mask != 0 {
            entries.append(
                ServerDLC(appID: row.appID, name: row.name, hash: 0, isCreatorDLC: false)
            )
            unmatched &= ~row.mask
        }
        // Unknown bits still consume a hash each, so account for them.
        var bit: UInt16 = 1
        while unmatched != 0, bit != 0 {
            if unmatched & bit != 0 {
                entries.append(
                    ServerDLC(appID: 0, name: "Unknown DLC (0x\(String(bit, radix: 16)))",
                              hash: 0, isCreatorDLC: false)
                )
                unmatched &= ~bit
            }
            bit <<= 1
        }

        for index in entries.indices {
            guard let hash = try? reader.uint32() else {
                throw DecodeError.truncated("DLC hashes")
            }
            entries[index].hash = hash
        }
        return entries
    }

    private static func readMods(reader: inout ByteReader, into payload: inout Payload) throws {
        guard let count = try? reader.byte(), count > 0 else { return }

        for index in 0..<Int(count) {
            guard let hash = try? reader.uint32(),
                  let idLength = try? reader.byte()
            else { throw DecodeError.truncated("mod \(index)") }

            var publishedID: UInt64
            switch idLength {
            case 1:
                publishedID = UInt64(try reader.byte())
            case 4:
                publishedID = UInt64(try reader.uint32())
            case 8:
                publishedID = try reader.uint64()
            case 19:
                // Marker for Creator DLC: the id is a 4-byte app id and there is no name.
                let appID = UInt64(try reader.uint32())
                payload.dlcs.append(
                    ServerDLC(
                        appID: appID,
                        name: creatorDLCNames[appID] ?? "Creator DLC \(appID)",
                        hash: hash,
                        isCreatorDLC: true
                    )
                )
                continue
            default:
                // An unknown length means the stream is out of sync; stop rather than
                // emit garbage mod entries.
                throw DecodeError.truncated("mod \(index) id length \(idLength)")
            }

            guard let nameLength = try? reader.byte() else {
                throw DecodeError.truncated("mod \(index) name length")
            }
            var name = ""
            if nameLength > 0 {
                guard let decoded = try? reader.string(length: Int(nameLength)) else {
                    throw DecodeError.truncated("mod \(index) name")
                }
                name = decoded
            }
            payload.mods.append(
                ServerMod(publishedFileID: publishedID, name: name, hash: hash)
            )
        }
    }

    private static func readSignatures(reader: inout ByteReader) throws -> [String] {
        guard let count = try? reader.byte(), count > 0 else { return [] }
        var signatures: [String] = []
        signatures.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard let length = try? reader.byte() else { break }
            if length == 0 { continue }
            guard let value = try? reader.string(length: Int(length)) else { break }
            signatures.append(value)
        }
        return signatures
    }
}
