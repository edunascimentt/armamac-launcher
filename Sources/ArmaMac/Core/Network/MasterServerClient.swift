import Foundation

/// Queries Valve's master server for the Arma 3 server list over UDP (`A2S_MASTER`).
///
/// The master server answers with pages of ~230 addresses; the last address of a page is
/// used as the seed for the next one, and a `0.0.0.0:0` entry marks the end of the list.
/// This path needs no API key, which is why it is the default provider.
struct MasterServerClient: Sendable {
    struct Options: Sendable {
        var host = "hl2master.steampowered.com"
        var port: UInt16 = 27_011
        var region: UInt8 = 0xFF  // 0xFF = rest of the world / all regions
        var timeout: Duration = .seconds(3)
        var maxPages = 200
        /// Extra master-server filters, e.g. `["dedicated": "1", "empty": "1"]`.
        var filters: [String: String] = ["empty": "1", "dedicated": "1"]
    }

    enum MasterError: Error, LocalizedError {
        case badResponse
        case noServers

        var errorDescription: String? {
            switch self {
            case .badResponse: "The Steam master server sent an unexpected reply."
            case .noServers: "The Steam master server returned no Arma 3 servers."
            }
        }
    }

    var options = Options()

    private static let responsePrefix: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x66, 0x0A]

    private var filterString: String {
        var parts = ["\\appid\\\(Arma3.appIDString)"]
        for key in options.filters.keys.sorted() {
            parts.append("\\\(key)\\\(options.filters[key]!)")
        }
        return parts.joined()
    }

    /// Fetches every page and returns the de-duplicated address list.
    /// `onPage` is called after each page so the UI can start querying early.
    func fetchAddresses(
        onPage: (@Sendable ([ServerAddress]) async -> Void)? = nil
    ) async throws -> [ServerAddress] {
        let socket = UDPSocket(host: options.host, port: options.port)
        defer { Task { await socket.close() } }

        var seed = "0.0.0.0:0"
        var all: [ServerAddress] = []
        var seen = Set<ServerAddress>()

        for _ in 0..<options.maxPages {
            try Task.checkCancellation()

            var writer = ByteWriter()
            writer.byte(0x31)
            writer.byte(options.region)
            writer.cString(seed)
            writer.cString(filterString)

            let response = try await socket.request(
                writer.data, timeout: options.timeout, retries: 1
            )
            let (page, reachedEnd) = try Self.parse(response)
            guard !page.isEmpty || reachedEnd else { throw MasterError.badResponse }

            var fresh: [ServerAddress] = []
            for address in page where seen.insert(address).inserted {
                fresh.append(address)
            }
            all.append(contentsOf: fresh)
            if let onPage, !fresh.isEmpty { await onPage(fresh) }

            if reachedEnd { break }
            guard let last = page.last else { break }
            seed = "\(last.host):\(last.gamePort)"
        }

        guard !all.isEmpty else { throw MasterError.noServers }
        return all
    }

    /// Returns the addresses in a page plus whether the terminator was seen.
    static func parse(_ data: Data) throws -> ([ServerAddress], Bool) {
        let bytes = [UInt8](data)
        guard bytes.count > responsePrefix.count,
              Array(bytes.prefix(responsePrefix.count)) == responsePrefix
        else { throw MasterError.badResponse }

        var addresses: [ServerAddress] = []
        var index = responsePrefix.count
        var reachedEnd = false

        while index + 6 <= bytes.count {
            let octets = bytes[index..<(index + 4)]
            // Address and port are big-endian here, unlike the rest of the A2S family.
            let port = UInt16(bytes[index + 4]) << 8 | UInt16(bytes[index + 5])
            index += 6

            if octets.allSatisfy({ $0 == 0 }), port == 0 {
                reachedEnd = true
                break
            }
            let host = octets.map(String.init).joined(separator: ".")
            addresses.append(ServerAddress(host: host, gamePort: port))
        }
        return (addresses, reachedEnd)
    }
}

/// Optional richer source: Steam's Web API returns name, map, players and the keyword blob
/// for up to 20 000 servers in one HTTPS call, so the list is populated instantly.
/// Requires a free Steam Web API key.
struct SteamWebAPIServerList: Sendable {
    var apiKey: String
    var limit = 20_000
    var session: URLSession = .shared

    struct Entry: Decodable, Sendable {
        var addr: String
        var gameport: Int?
        var name: String?
        var map: String?
        var players: Int?
        var max_players: Int?
        var bots: Int?
        var gametype: String?
        var version: String?
        var os: String?
        var secure: Bool?
        var dedicated: Bool?
        var product: String?
    }

    private struct Envelope: Decodable {
        struct Response: Decodable { var servers: [Entry]? }
        var response: Response
    }

    enum APIError: Error, LocalizedError {
        case badStatus(Int)
        case missingKey

        var errorDescription: String? {
            switch self {
            case let .badStatus(code):
                "Steam Web API returned HTTP \(code). Check that the key is valid."
            case .missingKey:
                "No Steam Web API key is configured."
            }
        }
    }

    func fetch() async throws -> [(ServerAddress, GameServer)] {
        guard !apiKey.isEmpty else { throw APIError.missingKey }

        var components = URLComponents(
            string: "https://api.steampowered.com/IGameServersService/GetServerList/v1/"
        )!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "filter", value: "\\appid\\\(Arma3.appIDString)\\dedicated\\1"),
        ]

        let (data, response) = try await session.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError.badStatus(http.statusCode)
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return (envelope.response.servers ?? []).compactMap { entry in
            let parts = entry.addr.split(separator: ":")
            guard parts.count == 2, let queryPort = UInt16(parts[1]) else { return nil }
            let host = String(parts[0])
            let gamePort = entry.gameport.flatMap { UInt16(exactly: $0) } ?? (queryPort &- 1)
            let address = ServerAddress(host: host, gamePort: gamePort, queryPort: queryPort)

            var server = GameServer(address: address)
            server.name = entry.name ?? ""
            server.map = entry.map ?? ""
            server.players = entry.players ?? 0
            server.maxPlayers = entry.max_players ?? 0
            server.botCount = entry.bots ?? 0
            server.version = entry.version ?? ""
            server.os = entry.os ?? ""
            server.isVAC = entry.secure ?? false
            server.isDedicated = entry.dedicated ?? true
            server.applyKeywords(ArmaKeywords(entry.gametype))
            return (address, server)
        }
    }
}
