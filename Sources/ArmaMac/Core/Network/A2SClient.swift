import Foundation

/// Steam's A2S query protocol (`A2S_INFO`, `A2S_PLAYER`, `A2S_RULES`), including the
/// challenge handshake Valve added in 2020 and multi-packet reassembly.
enum A2S {
    static let singlePacketHeader: UInt32 = 0xFFFF_FFFF
    static let multiPacketHeader: UInt32 = 0xFFFF_FFFE

    enum Request: UInt8 {
        case info = 0x54
        case player = 0x55
        case rules = 0x56
    }

    enum Response: UInt8 {
        case info = 0x49
        case player = 0x44
        case rules = 0x45
        case challenge = 0x41
    }

    static let infoPayload = "Source Engine Query"

    enum QueryError: Error, LocalizedError {
        case badHeader(UInt32)
        case unexpectedResponse(UInt8)
        case challengeLoop
        case compressedResponseUnsupported
        case incompletePacketSet(received: Int, expected: Int)

        var errorDescription: String? {
            switch self {
            case let .badHeader(value):
                "Unrecognised packet header 0x\(String(value, radix: 16))."
            case let .unexpectedResponse(value):
                "Unexpected response type 0x\(String(value, radix: 16))."
            case .challengeLoop:
                "The server kept asking for a new challenge."
            case .compressedResponseUnsupported:
                "The server sent a bzip2-compressed reply, which is not supported."
            case let .incompletePacketSet(received, expected):
                "Only \(received) of \(expected) reply packets arrived."
            }
        }
    }
}

/// Fields returned by `A2S_INFO`.
struct A2SInfo: Sendable {
    var protocolVersion: UInt8 = 0
    var name = ""
    var map = ""
    var folder = ""
    var game = ""
    var appID: UInt16 = 0
    var players: Int = 0
    var maxPlayers: Int = 0
    var bots: Int = 0
    var serverType: UInt8 = 0
    var environment: UInt8 = 0
    var visibility: UInt8 = 0
    var vac: UInt8 = 0
    var version = ""
    var port: UInt16?
    var steamID: UInt64?
    var keywords: String?
    var gameID: UInt64?

    var isPasswordProtected: Bool { visibility == 1 }
    var isDedicated: Bool { serverType == UInt8(ascii: "d") }

    var environmentName: String {
        switch environment {
        case UInt8(ascii: "l"): "Linux"
        case UInt8(ascii: "w"): "Windows"
        case UInt8(ascii: "m"), UInt8(ascii: "o"): "macOS"
        default: "Unknown"
        }
    }
}

/// Raw `A2S_RULES` key/value pairs, before Arma's sub-protocol is decoded.
struct A2SRules: Sendable {
    var pairs: [(key: [UInt8], value: [UInt8])] = []
}

/// A reusable query session against one server; keeps the socket and challenge alive across
/// the info/players/rules round trips.
actor A2SSession {
    private let address: ServerAddress
    private let timeout: Duration
    private let retries: Int
    private var socket: UDPSocket?
    private var challenge: UInt32?
    /// Duration of the most recent request/response exchange.
    private var lastRoundTrip: Duration?

    init(address: ServerAddress, timeout: Duration = .milliseconds(1_400), retries: Int = 1) {
        self.address = address
        self.timeout = timeout
        self.retries = retries
    }

    private func activeSocket() -> UDPSocket {
        if let socket { return socket }
        let created = UDPSocket(host: address.host, port: address.queryPort)
        socket = created
        return created
    }

    func close() async {
        await socket?.close()
        socket = nil
    }

    // MARK: - Public queries

    /// Round-trip time measured on the info query, useful as the server ping.
    ///
    /// Only the final exchange counts: the challenge handshake costs an extra round trip
    /// that would otherwise double every reported ping.
    func info() async throws -> (info: A2SInfo, ping: Duration) {
        let data = try await performQuery(.info)
        let ping = lastRoundTrip ?? .zero
        var reader = ByteReader(data)
        let type = try reader.byte()
        guard type == A2S.Response.info.rawValue else {
            throw A2S.QueryError.unexpectedResponse(type)
        }
        return (try Self.parseInfo(&reader), ping)
    }

    func players() async throws -> [ServerPlayer] {
        let data = try await performQuery(.player)
        var reader = ByteReader(data)
        let type = try reader.byte()
        guard type == A2S.Response.player.rawValue else {
            throw A2S.QueryError.unexpectedResponse(type)
        }
        return try Self.parsePlayers(&reader)
    }

    func rules() async throws -> A2SRules {
        let data = try await performQuery(.rules)
        var reader = ByteReader(data)
        let type = try reader.byte()
        guard type == A2S.Response.rules.rawValue else {
            throw A2S.QueryError.unexpectedResponse(type)
        }
        return try Self.parseRules(&reader)
    }

    // MARK: - Transport

    /// Sends a request, answering the challenge if the server demands one.
    private func performQuery(_ request: A2S.Request, attempt: Int = 0) async throws -> Data {
        guard attempt < 3 else { throw A2S.QueryError.challengeLoop }

        let payload = Self.buildRequest(request, challenge: challenge)
        let socket = activeSocket()
        let started = ContinuousClock.now
        let first = try await socket.request(payload, timeout: timeout, retries: retries)
        lastRoundTrip = ContinuousClock.now - started
        let body = try await reassemble(first: first, socket: socket)

        // A challenge reply is a bare 'A' + 4 bytes; retry the original request with it.
        var peek = ByteReader(body)
        let type = try peek.byte()
        if type == A2S.Response.challenge.rawValue {
            challenge = try peek.uint32()
            return try await performQuery(request, attempt: attempt + 1)
        }
        return body
    }

    private static func buildRequest(_ request: A2S.Request, challenge: UInt32?) -> Data {
        var writer = ByteWriter()
        writer.uint32(A2S.singlePacketHeader)
        writer.byte(request.rawValue)
        switch request {
        case .info:
            writer.cString(A2S.infoPayload)
            // Only append a challenge once the server has issued one; some servers reject
            // an unsolicited 0xFFFFFFFF tail on A2S_INFO.
            if let challenge { writer.uint32(challenge) }
        case .player, .rules:
            writer.uint32(challenge ?? A2S.singlePacketHeader)
        }
        return writer.data
    }

    /// Strips the transport header, collecting the remaining fragments when the reply is split.
    private func reassemble(first: Data, socket: UDPSocket) async throws -> Data {
        var reader = ByteReader(first)
        let header = try reader.uint32()

        if header == A2S.singlePacketHeader {
            return first.dropFirst(4)
        }
        guard header == A2S.multiPacketHeader else {
            throw A2S.QueryError.badHeader(header)
        }

        var state = Reassembly()
        try Self.ingest(first, into: &state)
        while state.fragments.count < state.expected {
            let next = try await socket.receive(timeout: timeout)
            try Self.ingest(next, into: &state)
        }
        guard state.expected > 0, state.fragments.count == state.expected else {
            throw A2S.QueryError.incompletePacketSet(
                received: state.fragments.count, expected: state.expected
            )
        }

        var combined = Data()
        for fragment in state.fragments.sorted(by: { $0.index < $1.index }) {
            combined.append(fragment.payload)
        }
        // The reassembled stream carries its own single-packet header.
        var joined = ByteReader(combined)
        if (try? joined.uint32()) == A2S.singlePacketHeader {
            return combined.dropFirst(4)
        }
        return combined
    }

    // MARK: - Multi-packet reassembly

    /// Accumulator for a split reply.
    struct Reassembly {
        struct Fragment { var index: Int; var payload: Data }
        var fragments: [Fragment] = []
        var expected = 0
        var packetID: UInt32 = 0
        var isCompressed = false
    }

    /// Folds one datagram of a split reply into `state`.
    static func ingest(_ datagram: Data, into state: inout Reassembly) throws {
        var reader = ByteReader(datagram)
        guard try reader.uint32() == A2S.multiPacketHeader else { return }
        let id = try reader.uint32()
        let total = Int(try reader.byte())
        let number = Int(try reader.byte())
        // Most Source-engine servers, Arma included, carry the split size here.
        if reader.remaining >= 2 { _ = try? reader.uint16() }

        if state.fragments.isEmpty {
            state.packetID = id
            state.expected = total
            state.isCompressed = id & 0x8000_0000 != 0
        }
        // Ignore stragglers from an earlier query that share the socket.
        guard id == state.packetID else { return }
        if state.isCompressed, number == 0 {
            throw A2S.QueryError.compressedResponseUnsupported
        }
        let payload = try reader.data(length: reader.remaining)
        guard !state.fragments.contains(where: { $0.index == number }) else { return }
        state.fragments.append(Reassembly.Fragment(index: number, payload: payload))
    }

    // MARK: - Parsing

    static func parseInfo(_ reader: inout ByteReader) throws -> A2SInfo {
        var info = A2SInfo()
        info.protocolVersion = try reader.byte()
        info.name = try reader.cString()
        info.map = try reader.cString()
        info.folder = try reader.cString()
        info.game = try reader.cString()
        info.appID = try reader.uint16()
        info.players = Int(try reader.byte())
        info.maxPlayers = Int(try reader.byte())
        info.bots = Int(try reader.byte())
        info.serverType = try reader.byte()
        info.environment = try reader.byte()
        info.visibility = try reader.byte()
        info.vac = try reader.byte()
        info.version = try reader.cString()

        guard reader.remaining >= 1 else { return info }
        let extraFlags = try reader.byte()
        if extraFlags & 0x80 != 0 { info.port = try reader.uint16() }
        if extraFlags & 0x10 != 0 { info.steamID = try reader.uint64() }
        if extraFlags & 0x40 != 0 {
            _ = try reader.uint16()          // spectator port
            _ = try reader.cString()         // spectator server name
        }
        if extraFlags & 0x20 != 0 { info.keywords = try reader.cString() }
        if extraFlags & 0x01 != 0 { info.gameID = try reader.uint64() }
        return info
    }

    static func parsePlayers(_ reader: inout ByteReader) throws -> [ServerPlayer] {
        let count = Int(try reader.byte())
        var players: [ServerPlayer] = []
        players.reserveCapacity(count)
        for slot in 0..<count {
            // Arma reports every player with index 0, so use the loop counter for identity.
            _ = try reader.byte()
            let name = try reader.cString()
            let score = try reader.int32()
            let seconds = try reader.float32()
            let duration = Duration.seconds(Double(max(0, seconds.isFinite ? seconds : 0)))
            players.append(
                ServerPlayer(index: slot, name: name, score: score, duration: duration)
            )
        }
        return players
    }

    static func parseRules(_ reader: inout ByteReader) throws -> A2SRules {
        let count = Int(try reader.uint16())
        var rules = A2SRules()
        rules.pairs.reserveCapacity(count)
        for _ in 0..<count {
            // A truncated tail is common on busy servers; keep whatever parsed cleanly.
            guard let key = try? reader.cStringBytes(),
                  let value = try? reader.cStringBytes() else { break }
            rules.pairs.append((key: Array(key), value: Array(value)))
        }
        return rules
    }
}
