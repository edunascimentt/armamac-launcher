import Foundation

extension GameServer {
    mutating func applyKeywords(_ keywords: ArmaKeywords) {
        battlEye = keywords.battlEye
        verifySignatures = keywords.verifySignatures
        requiredVersion = keywords.requiredVersion
        requiredBuild = keywords.requiredBuild
        serverState = keywords.serverState
        difficulty = keywords.difficulty
        equalModRequired = keywords.equalModRequired
        allowedFilePatching = keywords.allowedFilePatching
        country = keywords.country
        platform = keywords.platform
        timeLeft = keywords.timeLeft
        loadedContentHash = keywords.loadedContentHash
        if isPasswordProtected == false { isPasswordProtected = keywords.locked }
        if map.isEmpty { map = keywords.island }
    }

    mutating func apply(info: A2SInfo, ping: Duration) {
        name = info.name
        map = info.map
        gameDescription = info.game
        players = max(0, info.players - info.bots)
        maxPlayers = info.maxPlayers
        botCount = info.bots
        isPasswordProtected = info.isPasswordProtected
        isVAC = info.vac == 1
        isDedicated = info.isDedicated
        version = info.version
        os = info.environmentName
        self.ping = ping
        applyKeywords(ArmaKeywords(info.keywords))
        // Arma reports the game port in the info extra-data field; trust it over the guess.
        if let port = info.port, port != 0 {
            address = ServerAddress(host: address.host, gamePort: port, queryPort: address.queryPort)
        }
        lastRefreshed = .now
        queryFailed = false
    }

    mutating func apply(payload: ArmaServerBrowserProtocol.Payload) {
        mods = payload.mods
        dlcs = payload.dlcs
        signatures = payload.signatures
        modsLoaded = true
        if let difficulty = payload.difficulty {
            self.difficulty = difficulty.level
        }
    }
}

/// What to ask each server for. Rules are the expensive part, so the browser fetches them
/// lazily for the visible/selected rows unless the user asks for a full scan.
struct ServerQueryPlan: Sendable {
    var includePlayers = false
    var includeRules = false
    var timeout: Duration = .milliseconds(1_400)
    var retries = 1
}

/// Queries many servers concurrently with a bounded number of in-flight sockets.
struct ServerQueryService: Sendable {
    /// Sockets open at once. High enough to scan thousands of servers quickly, low enough
    /// to stay well inside the process file-descriptor limit.
    var concurrency = 96

    /// Refreshes one server in place.
    func query(
        address: ServerAddress,
        plan: ServerQueryPlan,
        existing: GameServer? = nil
    ) async -> GameServer {
        var server = existing ?? GameServer(address: address)
        let session = A2SSession(address: address, timeout: plan.timeout, retries: plan.retries)
        defer { Task { await session.close() } }

        do {
            let (info, ping) = try await session.info()
            server.apply(info: info, ping: ping)
        } catch {
            server.queryFailed = true
            server.lastRefreshed = .now
            return server
        }

        if plan.includeRules {
            do {
                let rules = try await session.rules()
                let payload = try ArmaServerBrowserProtocol.decode(rules: rules)
                server.apply(payload: payload)
            } catch {
                // A server that answers info but not rules is common (rules are rate limited);
                // keep the info we already have.
            }
        }

        if plan.includePlayers {
            server.playerList = (try? await session.players()) ?? []
            server.playersLoaded = true
        }

        return server
    }

    /// Streams results as they arrive so the table fills in progressively.
    func queryAll(
        addresses: [ServerAddress],
        plan: ServerQueryPlan,
        existing: [ServerAddress: GameServer] = [:],
        onResult: @Sendable @escaping (GameServer) async -> Void
    ) async {
        guard !addresses.isEmpty else { return }
        let limit = max(1, min(concurrency, addresses.count))

        await withTaskGroup(of: Void.self) { group in
            var iterator = addresses.makeIterator()
            var inFlight = 0

            func schedule(_ address: ServerAddress) {
                let previous = existing[address]
                group.addTask {
                    guard !Task.isCancelled else { return }
                    let server = await query(address: address, plan: plan, existing: previous)
                    await onResult(server)
                }
            }

            while inFlight < limit, let address = iterator.next() {
                schedule(address)
                inFlight += 1
            }

            while await group.next() != nil {
                if Task.isCancelled { break }
                if let address = iterator.next() { schedule(address) }
            }
        }
    }
}
