import XCTest
@testable import ArmaMac

final class ValveKeyValuesTests: XCTestCase {
    func testParsesNestedAppManifest() throws {
        let text = """
        "AppState"
        {
            "appid"        "107410"
            "name"         "Arma 3"
            "installdir"   "Arma 3"
            "UserConfig"
            {
                "language" "english"
                "BetaKey"  "profiling"
            }
        }
        """
        let parsed = try ValveKeyValues.parse(text)
        XCTAssertEqual(parsed.value(at: "AppState", "appid")?.stringValue, "107410")
        XCTAssertEqual(parsed.value(at: "AppState", "installdir")?.stringValue, "Arma 3")
        XCTAssertEqual(
            parsed.value(at: "AppState", "UserConfig", "language")?.stringValue, "english"
        )
    }

    func testKeyLookupIsCaseInsensitive() throws {
        let parsed = try ValveKeyValues.parse(#""LibraryFolders" { "0" { "path" "/tmp" } }"#)
        XCTAssertEqual(parsed.value(at: "libraryfolders", "0", "PATH")?.stringValue, "/tmp")
    }

    func testSkipsCommentsAndConditionals() throws {
        let text = """
        // leading comment
        "root"
        {
            "a" "1" [$WIN32]
            // "b" "2"
            "c" "3"
        }
        """
        let parsed = try ValveKeyValues.parse(text)
        XCTAssertEqual(parsed.value(at: "root", "a")?.intValue, 1)
        XCTAssertNil(parsed.value(at: "root", "b"))
        XCTAssertEqual(parsed.value(at: "root", "c")?.intValue, 3)
    }
}

final class ArmaConfigParserTests: XCTestCase {
    func testParsesModCpp() {
        let text = """
        name = "CBA_A3";
        picture = "logo.paa";
        author = "CBA Team";
        version = "3.15.8";
        description = "Community Base Addons";
        """
        let parsed = ArmaConfigParser.parse(text)
        XCTAssertEqual(parsed["name"]?.string, "CBA_A3")
        XCTAssertEqual(parsed["author"]?.string, "CBA Team")
        XCTAssertEqual(parsed["version"]?.string, "3.15.8")
    }

    func testParsesMetaCppPublishedID() {
        let text = """
        protocol = 1;
        publishedid = 450814997;
        name = "CBA_A3";
        timestamp = 133464422400000000;
        """
        let parsed = ArmaConfigParser.parse(text)
        XCTAssertEqual(parsed["publishedid"]?.uint64Value, 450_814_997)
        XCTAssertEqual(parsed["timestamp"]?.uint64Value, 133_464_422_400_000_000)
    }

    func testIgnoresNestedClassesAndComments() {
        let text = """
        name = "Test";
        // author = "Nope";
        class Extra {
            name = "Inner";
        };
        version = "1.0";
        """
        let parsed = ArmaConfigParser.parse(text)
        XCTAssertEqual(parsed["name"]?.string, "Test")
        XCTAssertEqual(parsed["version"]?.string, "1.0")
        XCTAssertNil(parsed["author"])
    }
}

final class ArmaKeywordsTests: XCTestCase {
    func testParsesRealKeywordString() {
        let keywords = ArmaKeywords("bt,r160,n1490,s7,i1,mf,lf,vt,dt,tdm,g65545,h9fe4bb59,f0,c0-0,pw,e0,j0,k0")
        XCTAssertTrue(keywords.battlEye)
        XCTAssertEqual(keywords.requiredVersion, "1.60")
        XCTAssertEqual(keywords.requiredBuild, 1_490)
        XCTAssertEqual(keywords.serverState, .playing)
        XCTAssertEqual(keywords.difficulty, 1)
        XCTAssertFalse(keywords.equalModRequired)
        XCTAssertFalse(keywords.locked)
        XCTAssertTrue(keywords.verifySignatures)
        XCTAssertTrue(keywords.dedicated)
        XCTAssertEqual(keywords.loadedContentHash, "9fe4bb59")
    }

    func testHandlesNegativeCoordinates() {
        let keywords = ArmaKeywords("c-122-37")
        XCTAssertEqual(keywords.longitude, -122)
        XCTAssertEqual(keywords.latitude, 37)
    }

    func testEmptyKeywordsAreHarmless() {
        let keywords = ArmaKeywords(nil)
        XCTAssertFalse(keywords.battlEye)
        XCTAssertEqual(keywords.serverState, .none)
    }
}

final class ArmaServerBrowserProtocolTests: XCTestCase {
    func testUnescapeTable() {
        var output: [UInt8] = []
        ArmaServerBrowserProtocol.unescape(
            [0x01, 0x01, 0x01, 0x02, 0x01, 0x03, 0x41], into: &output
        )
        XCTAssertEqual(output, [0x01, 0x00, 0xFF, 0x41])
    }

    func testUnescapeLeavesUnknownSequencesAlone() {
        var output: [UInt8] = []
        ArmaServerBrowserProtocol.unescape([0x01, 0x09, 0x42], into: &output)
        XCTAssertEqual(output, [0x01, 0x09, 0x42])
    }

    /// Builds a v3 payload the way a server would, then checks the decoder recovers it.
    func testDecodesModsAndSignatures() throws {
        var writer = ByteWriter()
        writer.byte(3)                       // protocol version
        writer.byte(0)                       // flags
        writer.uint16(0x0004)                // DLC bitmask: Helicopters
        writer.byte(0b1000_0010)             // difficulty: veteran-ish, third person on
        writer.byte(0x01)                    // crosshair on
        writer.uint32(0xDEAD_BEEF)           // hash for the one DLC

        writer.byte(3)                       // mod count
        // Mod 1: 8-byte workshop id
        writer.uint32(0x1111_1111)
        writer.byte(8)
        writer.raw([UInt8](repeating: 0, count: 0))
        var idWriter = ByteWriter()
        idWriter.uint32(450_814_997)
        idWriter.uint32(0)
        writer.raw(idWriter.bytes)
        writer.byte(UInt8("CBA_A3".utf8.count))
        writer.raw(Array("CBA_A3".utf8))
        // Mod 2: 4-byte id, no name
        writer.uint32(0x2222_2222)
        writer.byte(4)
        writer.uint32(463_939_057)
        writer.byte(0)
        // Mod 3: Creator DLC marker
        writer.uint32(0x3333_3333)
        writer.byte(19)
        writer.uint32(1_227_700)

        writer.byte(2)                       // signature count
        writer.byte(UInt8("cba".utf8.count))
        writer.raw(Array("cba".utf8))
        writer.byte(UInt8("bi".utf8.count))
        writer.raw(Array("bi".utf8))

        let payload = try ArmaServerBrowserProtocol.decodeMessage(writer.bytes)

        XCTAssertEqual(payload.version, 3)
        XCTAssertEqual(payload.mods.count, 2)
        XCTAssertEqual(payload.mods[0].publishedFileID, 450_814_997)
        XCTAssertEqual(payload.mods[0].name, "CBA_A3")
        XCTAssertEqual(payload.mods[0].hash, 0x1111_1111)
        XCTAssertEqual(payload.mods[1].publishedFileID, 463_939_057)
        XCTAssertEqual(payload.mods[1].name, "")

        // One regular DLC plus the Creator DLC pulled out of the mod block.
        XCTAssertEqual(payload.dlcs.count, 2)
        XCTAssertEqual(payload.dlcs[0].name, "Helicopters")
        XCTAssertEqual(payload.dlcs[0].hash, 0xDEAD_BEEF)
        XCTAssertTrue(payload.dlcs[1].isCreatorDLC)
        XCTAssertEqual(payload.dlcs[1].appID, 1_227_700)
        XCTAssertEqual(payload.dlcs[1].name, "S.O.G. Prairie Fire")

        XCTAssertEqual(payload.signatures, ["cba", "bi"])
        XCTAssertEqual(payload.difficulty?.thirdPerson, true)
        XCTAssertEqual(payload.difficulty?.crosshair, true)
    }

    /// Rules keys are `[page, pageCount]`; anything else is an ordinary rule.
    func testDecodeReassemblesPagedRules() throws {
        var message = ByteWriter()
        message.byte(3)
        message.byte(0)
        message.uint16(0)
        message.byte(0)
        message.byte(0)
        message.byte(0)   // no mods
        message.byte(0)   // no signatures

        var rules = A2SRules()
        // Split the message across two pages, plus one unrelated rule.
        let bytes = message.bytes
        let half = bytes.count / 2
        rules.pairs.append((key: [0x00, 0x01], value: Array(bytes[0..<half])))
        rules.pairs.append((key: [0x01, 0x01], value: Array(bytes[half...])))
        rules.pairs.append((key: Array("mission".utf8), value: Array("Escape".utf8)))

        let payload = try ArmaServerBrowserProtocol.decode(rules: rules)
        XCTAssertEqual(payload.version, 3)
        XCTAssertTrue(payload.mods.isEmpty)
        XCTAssertEqual(payload.extraRules["mission"], "Escape")
    }

    func testRejectsUnknownProtocolVersion() {
        XCTAssertThrowsError(try ArmaServerBrowserProtocol.decodeMessage([9, 0, 0, 0]))
    }
}

final class A2SParsingTests: XCTestCase {
    func testParsesInfoWithKeywords() throws {
        var writer = ByteWriter()
        writer.byte(17)                      // protocol
        writer.cString("Test Server")
        writer.cString("Altis")
        writer.cString("Arma3")
        writer.cString("ArmA3")
        writer.uint16(107)                   // truncated app id
        writer.byte(30)                      // players (includes bots)
        writer.byte(64)                      // max players
        writer.byte(2)                       // bots
        writer.byte(UInt8(ascii: "d"))
        writer.byte(UInt8(ascii: "w"))
        writer.byte(0)                       // visibility
        writer.byte(1)                       // VAC
        writer.cString("2.18.152525")
        writer.byte(0x80 | 0x20)             // EDF: port + keywords
        writer.uint16(2_302)
        writer.cString("bt,r218,s7,vt,dt")

        var reader = ByteReader(writer.data)
        let info = try A2SSession.parseInfo(&reader)

        XCTAssertEqual(info.name, "Test Server")
        XCTAssertEqual(info.map, "Altis")
        XCTAssertEqual(info.maxPlayers, 64)
        XCTAssertEqual(info.bots, 2)
        XCTAssertEqual(info.port, 2_302)
        XCTAssertEqual(info.environmentName, "Windows")
        XCTAssertFalse(info.isPasswordProtected)

        var server = GameServer(address: ServerAddress(host: "1.2.3.4", gamePort: 2_302))
        server.apply(info: info, ping: .milliseconds(42))
        // Bots are excluded from the human player count.
        XCTAssertEqual(server.players, 28)
        XCTAssertTrue(server.battlEye)
        XCTAssertEqual(server.serverState, .playing)
    }

    func testParsesPlayerList() throws {
        var writer = ByteWriter()
        writer.byte(2)
        writer.byte(0)
        writer.cString("Alice")
        writer.uint32(UInt32(bitPattern: 12))
        writer.uint32(0x4479_0000)  // ~997 seconds as float32
        writer.byte(0)
        writer.cString("Bob")
        writer.uint32(UInt32(bitPattern: -3))
        writer.uint32(0)

        var reader = ByteReader(writer.data)
        let players = try A2SSession.parsePlayers(&reader)

        XCTAssertEqual(players.count, 2)
        XCTAssertEqual(players[0].name, "Alice")
        XCTAssertEqual(players[0].score, 12)
        XCTAssertEqual(players[1].name, "Bob")
        XCTAssertEqual(players[1].score, -3)
        // Indexes come from the loop, since Arma reports every player as index 0.
        XCTAssertEqual(players.map(\.index), [0, 1])
    }

    func testParsesRulesPairs() throws {
        var writer = ByteWriter()
        writer.uint16(2)
        writer.cString("a")
        writer.cString("1")
        writer.cString("b")
        writer.cString("2")

        var reader = ByteReader(writer.data)
        let rules = try A2SSession.parseRules(&reader)
        XCTAssertEqual(rules.pairs.count, 2)
        XCTAssertEqual(String(decoding: rules.pairs[0].key, as: UTF8.self), "a")
        XCTAssertEqual(String(decoding: rules.pairs[1].value, as: UTF8.self), "2")
    }

    func testTruncatedRulesKeepWhatParsed() throws {
        var writer = ByteWriter()
        writer.uint16(5)          // claims five pairs
        writer.cString("a")
        writer.cString("1")
        writer.raw(Array("bcd".utf8))  // truncated, no terminator

        var reader = ByteReader(writer.data)
        let rules = try A2SSession.parseRules(&reader)
        XCTAssertEqual(rules.pairs.count, 1)
    }
}

final class MasterServerParsingTests: XCTestCase {
    func testParsesAddressPage() throws {
        var bytes: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x66, 0x0A]
        bytes += [192, 0, 2, 10, 0x08, 0xFF]   // 192.0.2.10:2303
        bytes += [198, 51, 100, 7, 0x08, 0xFE] // 198.51.100.7:2302
        bytes += [0, 0, 0, 0, 0, 0]            // terminator

        let (addresses, reachedEnd) = try MasterServerClient.parse(Data(bytes))
        XCTAssertTrue(reachedEnd)
        XCTAssertEqual(addresses.count, 2)
        XCTAssertEqual(addresses[0].host, "192.0.2.10")
        XCTAssertEqual(addresses[0].gamePort, 2_303)
        XCTAssertEqual(addresses[1].host, "198.51.100.7")
        XCTAssertEqual(addresses[1].gamePort, 2_302)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try MasterServerClient.parse(Data([0x01, 0x02, 0x03])))
    }

    func testQueryPortDefaultsToGamePortPlusOne() {
        let address = ServerAddress(host: "10.0.0.1", gamePort: 2_302)
        XCTAssertEqual(address.queryPort, 2_303)
    }
}

final class PresetHTMLTests: XCTestCase {
    private let sample = """
    <?xml version="1.0" encoding="utf-8"?>
    <html>
      <head><meta name="arma:Type" content="preset" /></head>
      <body>
        <h1>Arma 3 - Preset <strong>Unit Modset</strong></h1>
        <div class="mod-list">
          <table>
            <tr data-type="ModContainer">
              <td data-type="DisplayName">CBA_A3</td>
              <td><span class="from-steam">Steam</span></td>
              <td><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=450814997" data-type="Link">link</a></td>
            </tr>
            <tr data-type="ModContainer">
              <td data-type="DisplayName">ace &amp; friends</td>
              <td><span class="from-steam">Steam</span></td>
              <td><a href="https://steamcommunity.com/sharedfiles/filedetails/?id=463939057" data-type="Link">link</a></td>
            </tr>
          </table>
        </div>
      </body>
    </html>
    """

    func testParsesPreset() {
        let preset = PresetHTML.parse(html: sample)
        XCTAssertEqual(preset.name, "Unit Modset")
        XCTAssertEqual(preset.mods.count, 2)
        XCTAssertEqual(preset.mods[0].publishedFileID, 450_814_997)
        XCTAssertEqual(preset.mods[1].name, "ace & friends")
        XCTAssertEqual(preset.mods[1].publishedFileID, 463_939_057)
    }

    func testExportRoundTrips() {
        let mods = [
            Mod(
                path: URL(filePath: "/tmp/450814997"),
                origin: .workshop,
                publishedFileID: 450_814_997,
                name: "CBA_A3",
                lastScanned: .now
            ),
            Mod(
                path: URL(filePath: "/tmp/@Local"),
                origin: .local,
                publishedFileID: nil,
                name: "Local Mod",
                lastScanned: .now
            ),
        ]
        let html = PresetHTML.export(name: "Round Trip", mods: mods)
        let parsed = PresetHTML.parse(html: html)

        XCTAssertEqual(parsed.name, "Round Trip")
        XCTAssertEqual(parsed.mods.count, 2)
        XCTAssertEqual(parsed.mods[0].publishedFileID, 450_814_997)
        XCTAssertNil(parsed.mods[1].publishedFileID)
    }

    func testExtractsWorkshopIDFromURL() {
        XCTAssertEqual(
            PresetHTML.workshopID(
                fromURL: "https://steamcommunity.com/sharedfiles/filedetails/?id=1234567890&searchtext=x"
            ),
            1_234_567_890
        )
        XCTAssertNil(PresetHTML.workshopID(fromURL: "https://example.com/nope"))
    }
}

final class LaunchArgumentTests: XCTestCase {
    private func makeInstallation(container: RuntimeContainer) -> GameInstallation {
        let root = URL(filePath: "/Games/Steam")
        let library = SteamLibrary(root: root, container: container)
        let directory = root.appending(path: "steamapps/common/Arma 3")
        return GameInstallation(
            directory: directory,
            library: library,
            executables: [
                GameExecutable(url: directory.appending(path: "arma3_x64.exe"), kind: .win64)
            ]
        )
    }

    func testGameArgumentsCoverTheCommonSwitches() {
        var options = LaunchOptions()
        options.skipIntro = true
        options.noSplash = true
        options.windowed = true
        options.maxMemoryMB = 8_192
        options.profileName = "Recon"
        options.customParameters = #"-nologs -world="empty world""#

        let arguments = options.gameArguments()
        XCTAssertTrue(arguments.contains("-skipIntro"))
        XCTAssertTrue(arguments.contains("-noSplash"))
        XCTAssertTrue(arguments.contains("-window"))
        XCTAssertTrue(arguments.contains("-maxMem=8192"))
        XCTAssertTrue(arguments.contains("-name=Recon"))
        XCTAssertTrue(arguments.contains("-nologs"))
        // Quoted custom parameters stay in one piece.
        XCTAssertTrue(arguments.contains("-world=empty world"))
    }

    func testConnectArguments() {
        let target = ConnectTarget(
            address: ServerAddress(host: "203.0.113.5", gamePort: 2_402),
            password: "secret"
        )
        XCTAssertEqual(
            target.arguments(),
            ["-connect=203.0.113.5", "-port=2402", "-password=secret"]
        )
    }

    func testModArgumentUsesWorkshopSymlinksAndOfficialFolderNames() {
        let installation = makeInstallation(container: .native)
        let workshopMod = Mod(
            path: URL(filePath: "/Games/Steam/steamapps/workshop/content/107410/450814997"),
            origin: .workshop,
            publishedFileID: 450_814_997,
            name: "CBA_A3",
            lastScanned: .now
        )
        let officialMod = Mod(
            path: installation.directory.appending(path: "curator"),
            origin: .bundled,
            publishedFileID: nil,
            name: "Zeus",
            lastScanned: .now
        )
        let linked = [
            "@CBA_A3": installation.workshopLinkDirectory.appending(path: "@CBA_A3")
        ]

        let argument = GameLauncher().makeModArgument(
            installation: installation, mods: [workshopMod, officialMod], linkedMods: linked
        )
        // The native build takes POSIX separators.
        XCTAssertEqual(argument, "-mod=!Workshop/@CBA_A3;curator;")
    }

    func testModArgumentUsesBackslashesUnderWine() {
        let installation = makeInstallation(
            container: .crossover(bottle: "Steam", prefix: URL(filePath: "/prefix"))
        )
        let workshopMod = Mod(
            path: URL(filePath: "/Games/Steam/steamapps/workshop/content/107410/450814997"),
            origin: .workshop,
            publishedFileID: 450_814_997,
            name: "CBA_A3",
            lastScanned: .now
        )
        let linked = [
            "@CBA_A3": installation.workshopLinkDirectory.appending(path: "@CBA_A3")
        ]
        let argument = GameLauncher().makeModArgument(
            installation: installation, mods: [workshopMod], linkedMods: linked
        )
        XCTAssertEqual(argument, #"-mod=!Workshop\@CBA_A3;"#)
    }

    private func makeNativeInstallation(_ kinds: [GameExecutable.Kind]) -> GameInstallation {
        let directory = URL(filePath: "/Games/Arma 3")
        return GameInstallation(
            directory: directory,
            library: SteamLibrary(root: URL(filePath: "/Games"), container: .native),
            executables: kinds.map {
                GameExecutable(url: directory.appending(path: "\($0.rawValue).app"), kind: $0)
            }
        )
    }

    /// Bohemia's Apple Silicon build has no BattlEye, so it must not be chosen when
    /// BattlEye is required — that would get the player rejected by most public servers.
    func testBattlEyeForcesTheIntelMacBuild() {
        let installation = makeNativeInstallation([.macOSAppleSilicon, .macOSIntel])
        XCTAssertEqual(installation.executable(battlEye: true)?.kind, .macOSIntel)
        XCTAssertFalse(
            installation.battlEyeUnavailable(for: {
                var options = LaunchOptions()
                options.useBattlEye = true
                return options
            }())
        )
    }

    func testAppleSiliconWinsWhenBattlEyeIsOff() {
        let installation = makeNativeInstallation([.macOSIntel, .macOSAppleSilicon])
        #if arch(arm64)
        XCTAssertEqual(installation.executable(battlEye: false)?.kind, .macOSAppleSilicon)
        #else
        XCTAssertEqual(installation.executable(battlEye: false)?.kind, .macOSIntel)
        #endif
    }

    /// With only the Apple Silicon build installed the launcher still starts the game, but
    /// reports that BattlEye cannot be satisfied.
    func testReportsWhenOnlyTheAppleSiliconBuildExists() {
        let installation = makeNativeInstallation([.macOSAppleSilicon])
        XCTAssertEqual(installation.executable(battlEye: true)?.kind, .macOSAppleSilicon)

        var options = LaunchOptions()
        options.useBattlEye = true
        XCTAssertTrue(installation.battlEyeUnavailable(for: options))
        options.useBattlEye = false
        XCTAssertFalse(installation.battlEyeUnavailable(for: options))
    }

    func testWindowsBattlEyeLauncherIsPreferred() {
        let directory = URL(filePath: "/Games/Arma 3")
        let installation = GameInstallation(
            directory: directory,
            library: SteamLibrary(
                root: URL(filePath: "/Games"),
                container: .crossover(bottle: "Steam", prefix: URL(filePath: "/prefix"))
            ),
            executables: [
                GameExecutable(url: directory.appending(path: "arma3_x64.exe"), kind: .win64),
                GameExecutable(
                    url: directory.appending(path: "arma3battleye.exe"), kind: .win64BattlEye
                ),
            ]
        )
        XCTAssertEqual(installation.executable(battlEye: true)?.kind, .win64BattlEye)
        XCTAssertEqual(installation.executable(battlEye: false)?.kind, .win64)
    }

    func testModArgumentIsNilWithoutMods() {
        let installation = makeInstallation(container: .native)
        XCTAssertNil(
            GameLauncher().makeModArgument(installation: installation, mods: [], linkedMods: [:])
        )
    }

    func testLinkNameSanitisesIllegalCharacters() {
        let mod = Mod(
            path: URL(filePath: "/tmp/123"),
            origin: .workshop,
            publishedFileID: 123,
            name: "Bad/Name:Here",
            lastScanned: .now
        )
        let name = ModLinker.linkName(for: mod)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasPrefix("@"))
    }

    /// Arma re-parses `-mod=` out of the raw command line, so a single space anywhere in
    /// the list truncates it and *no* mods load — not just the one with the space.
    func testLinkNameHasNoSpaces() {
        let mod = Mod(
            path: URL(filePath: "/tmp/463939057"),
            origin: .workshop,
            publishedFileID: 463_939_057,
            name: "Advanced Combat Environment 3.21.1",
            lastScanned: .now
        )
        XCTAssertEqual(ModLinker.linkName(for: mod), "@Advanced_Combat_Environment_3.21.1")
    }

    func testModArgumentNeverContainsSpaces() {
        let installation = makeInstallation(container: .native)
        let mods = ["Advanced Combat Environment", "Better Inventory"].enumerated().map {
            Mod(
                path: URL(filePath: "/tmp/\($0.offset)"),
                origin: .workshop,
                publishedFileID: UInt64($0.offset + 1),
                name: $0.element,
                lastScanned: .now
            )
        }
        let linked = Dictionary(uniqueKeysWithValues: mods.map { mod in
            let name = ModLinker.linkName(for: mod)
            return (name, installation.workshopLinkDirectory.appending(path: name))
        })

        let argument = GameLauncher().makeModArgument(
            installation: installation, mods: mods, linkedMods: linked
        )
        XCTAssertNotNil(argument)
        XCTAssertFalse(argument!.contains(" "))
        XCTAssertTrue(argument!.contains("!Workshop/@Advanced_Combat_Environment"))
        XCTAssertTrue(argument!.contains("!Workshop/@Better_Inventory"))
    }
}

final class WinePathMapperTests: XCTestCase {
    /// Builds a throwaway prefix with the usual dosdevices layout.
    private func makePrefix() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-prefix-\(UUID().uuidString)")
        let driveC = root.appending(path: "drive_c")
        let dosdevices = root.appending(path: "dosdevices")
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "c:"), withDestinationURL: driveC
        )
        try FileManager.default.createSymbolicLink(
            at: dosdevices.appending(path: "z:"), withDestinationURL: URL(filePath: "/")
        )
        return root
    }

    func testMapsHostPathIntoDriveC() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }

        let mapper = WinePathMapper(prefix: prefix)
        let inside = prefix.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        XCTAssertEqual(
            mapper.windowsPath(for: inside),
            #"C:\Program Files (x86)\Steam\steamapps"#
        )
    }

    func testFallsBackToZDriveForPathsOutsideThePrefix() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }

        let mapper = WinePathMapper(prefix: prefix)
        let mapped = mapper.windowsPath(for: URL(filePath: "/usr/local/share"))
        XCTAssertEqual(mapped, #"Z:\usr\local\share"#)
    }

    func testRoundTripsBackToHostPath() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }

        let mapper = WinePathMapper(prefix: prefix)
        let host = mapper.hostURL(fromWindowsPath: #"C:\Games\Arma 3"#)
        XCTAssertEqual(
            host?.standardizedFileURL.path(percentEncoded: false),
            prefix.appending(path: "drive_c/Games/Arma 3")
                .standardizedFileURL.path(percentEncoded: false)
        )
    }
}

final class ModLinkerTests: XCTestCase {
    func testCreatesAndPrunesSymlinks() throws {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-link-\(UUID().uuidString)")
        let gameDirectory = root.appending(path: "Arma 3")
        // A realistic Steam workshop path: pruning only reclaims links it created there.
        let workshop = root
            .appending(path: "steamapps/workshop/content/107410/450814997")
        try fileManager.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: workshop.appending(path: "addons"), withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let installation = GameInstallation(
            directory: gameDirectory,
            library: SteamLibrary(root: root, container: .native),
            executables: []
        )
        let mod = Mod(
            path: workshop,
            origin: .workshop,
            publishedFileID: 450_814_997,
            name: "CBA_A3",
            lastScanned: .now
        )

        let linker = ModLinker(installation: installation)
        let result = try linker.synchronise(mods: [mod])
        XCTAssertEqual(result.created, 1)

        let link = installation.workshopLinkDirectory.appending(path: "@CBA_A3")
        let destination = try fileManager.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        )
        XCTAssertEqual(
            URL(filePath: destination).standardizedFileURL.path(percentEncoded: false),
            workshop.standardizedFileURL.path(percentEncoded: false)
        )

        // Re-running reuses the link rather than recreating it.
        let second = try linker.synchronise(mods: [mod])
        XCTAssertEqual(second.reused, 1)
        XCTAssertEqual(second.created, 0)

        // Dropping the mod prunes the link.
        let third = try linker.synchronise(mods: [])
        XCTAssertEqual(third.removed, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: link.path(percentEncoded: false)))
    }

    func testNeverDeletesRealDirectories() throws {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-safe-\(UUID().uuidString)")
        let gameDirectory = root.appending(path: "Arma 3")
        let realFolder = gameDirectory.appending(path: "!Workshop/@Handmade")
        try fileManager.createDirectory(at: realFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let installation = GameInstallation(
            directory: gameDirectory,
            library: SteamLibrary(root: root, container: .native),
            executables: []
        )
        _ = ModLinker(installation: installation).pruneLinks(keeping: [])
        XCTAssertTrue(fileManager.fileExists(atPath: realFolder.path(percentEncoded: false)))
    }
}

final class ModScannerTests: XCTestCase {
    func testRecognisesModDirectoriesAndReadsMetadata() throws {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-scan-\(UUID().uuidString)")
        let modDirectory = root.appending(path: "450814997")
        try fileManager.createDirectory(
            at: modDirectory.appending(path: "addons"), withIntermediateDirectories: true
        )
        try #"name = "CBA_A3";\#nauthor = "CBA Team";"#
            .write(to: modDirectory.appending(path: "mod.cpp"), atomically: true, encoding: .utf8)
        try "publishedid = 450814997;\ntimestamp = 133464422400000000;"
            .write(to: modDirectory.appending(path: "meta.cpp"), atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: root) }

        let scanner = ModScanner()
        XCTAssertTrue(scanner.isModDirectory(modDirectory))

        let mod = try XCTUnwrap(scanner.makeMod(at: modDirectory, origin: .workshop))
        XCTAssertEqual(mod.name, "CBA_A3")
        XCTAssertEqual(mod.author, "CBA Team")
        XCTAssertEqual(mod.publishedFileID, 450_814_997)
    }

    func testFallsBackToFolderNameForWorkshopID() throws {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-scan2-\(UUID().uuidString)")
        let modDirectory = root.appending(path: "463939057")
        try fileManager.createDirectory(
            at: modDirectory.appending(path: "addons"), withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: root) }

        let mod = try XCTUnwrap(ModScanner().makeMod(at: modDirectory, origin: .workshop))
        XCTAssertEqual(mod.publishedFileID, 463_939_057)
        XCTAssertEqual(mod.name, "463939057")
    }

    func testIgnoresPlainDirectories() throws {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-scan3-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        XCTAssertFalse(ModScanner().isModDirectory(root))
        XCTAssertNil(ModScanner().makeMod(at: root, origin: .local))
    }
}

final class ServerFilterTests: XCTestCase {
    @MainActor
    private func makeBrowser(_ servers: [GameServer]) -> ServerBrowserModel {
        let browser = ServerBrowserModel()
        for server in servers {
            browser.upsert(server)
        }
        return browser
    }

    private func makeServer(
        host: String,
        name: String,
        players: Int,
        maxPlayers: Int = 64,
        ping: Duration? = .milliseconds(30),
        battlEye: Bool = true,
        locked: Bool = false,
        mods: [ServerMod] = []
    ) -> GameServer {
        var server = GameServer(address: ServerAddress(host: host, gamePort: 2_302))
        server.name = name
        server.players = players
        server.maxPlayers = maxPlayers
        server.ping = ping
        server.battlEye = battlEye
        server.isPasswordProtected = locked
        server.mods = mods
        server.modsLoaded = true
        server.serverState = .playing
        return server
    }

    @MainActor
    func testFiltersAndSorting() {
        let browser = makeBrowser([
            makeServer(host: "1.1.1.1", name: "Empty Vanilla", players: 0),
            makeServer(host: "2.2.2.2", name: "Busy Modded", players: 40,
                       mods: [ServerMod(publishedFileID: 1, name: "CBA", hash: 0)]),
            makeServer(host: "3.3.3.3", name: "Locked", players: 5, locked: true),
            makeServer(host: "4.4.4.4", name: "No BattlEye", players: 12, battlEye: false),
        ])

        XCTAssertEqual(browser.visibleServers.count, 4)

        browser.filter.hideEmpty = true
        XCTAssertFalse(browser.visibleServers.contains { $0.name == "Empty Vanilla" })

        browser.filter.hidePasswordProtected = true
        XCTAssertFalse(browser.visibleServers.contains { $0.name == "Locked" })

        browser.filter.requireBattlEye = true
        XCTAssertFalse(browser.visibleServers.contains { $0.name == "No BattlEye" })

        browser.filter.modFilter = .modded
        XCTAssertEqual(browser.visibleServers.map(\.name), ["Busy Modded"])

        browser.filter = ServerFilter()
        browser.filter.searchText = "locked"
        XCTAssertEqual(browser.visibleServers.map(\.name), ["Locked"])

        browser.filter = ServerFilter()
        browser.sortRules = [ServerSortRule(field: .players, ascending: false)]
        XCTAssertEqual(browser.visibleServers.first?.name, "Busy Modded")
        browser.sortRules = [ServerSortRule(field: .players, ascending: true)]
        XCTAssertEqual(browser.visibleServers.first?.name, "Empty Vanilla")
    }

    @MainActor
    func testOnlyInstalledModsFilter() {
        let needed = ServerMod(publishedFileID: 450_814_997, name: "CBA_A3", hash: 0)
        let browser = makeBrowser([
            makeServer(host: "1.1.1.1", name: "Needs CBA", players: 10, mods: [needed])
        ])
        browser.filter.onlyInstalledMods = true

        XCTAssertTrue(browser.visibleServers.isEmpty)
        browser.installedWorkshopIDs = [450_814_997]
        XCTAssertEqual(browser.visibleServers.count, 1)
    }


    /// The default chain answers "busiest server I can actually play on": most players
    /// first, and among servers with the same player count, the lowest ping wins.
    @MainActor
    func testSortsByPlayersThenPing() {
        let browser = makeBrowser([
            makeServer(host: "1.1.1.1", name: "Busy Far", players: 40, ping: .milliseconds(300)),
            makeServer(host: "2.2.2.2", name: "Busy Near", players: 40, ping: .milliseconds(20)),
            makeServer(host: "3.3.3.3", name: "Busy Mid", players: 40, ping: .milliseconds(120)),
            makeServer(host: "4.4.4.4", name: "Quiet Near", players: 3, ping: .milliseconds(5)),
        ])
        browser.sortRules = [
            ServerSortRule(field: .players, ascending: false),
            ServerSortRule(field: .ping, ascending: true),
        ]

        XCTAssertEqual(
            browser.visibleServers.map(\.name),
            ["Busy Near", "Busy Mid", "Busy Far", "Quiet Near"]
        )
        XCTAssertEqual(browser.sortOrder.count, 2)
    }

    /// Three levels: same players and same ping, broken by mod count.
    @MainActor
    func testThirdLevelBreaksRemainingTies() {
        var withMods = makeServer(host: "1.1.1.1", name: "Modded", players: 10,
                                  ping: .milliseconds(50))
        withMods.mods = [ServerMod(publishedFileID: 1, name: "CBA", hash: 0)]
        let vanilla = makeServer(host: "2.2.2.2", name: "Vanilla", players: 10,
                                 ping: .milliseconds(50))
        let browser = makeBrowser([withMods, vanilla])

        browser.sortRules = [
            ServerSortRule(field: .players, ascending: false),
            ServerSortRule(field: .ping, ascending: true),
            ServerSortRule(field: .mods, ascending: true),
        ]
        XCTAssertEqual(browser.visibleServers.map(\.name), ["Vanilla", "Modded"])

        browser.setSortAscending(false, atLevel: 2)
        XCTAssertEqual(browser.visibleServers.map(\.name), ["Modded", "Vanilla"])
    }

    @MainActor
    func testEditingTheChain() {
        let browser = makeBrowser([])
        browser.sortRules = [ServerSortRule(field: .players, ascending: false)]

        // Adding a level uses the field's natural direction.
        browser.setSortField(.ping, atLevel: 1)
        XCTAssertEqual(browser.sortRules.count, 2)
        XCTAssertTrue(browser.sortRules[1].ascending)

        // A field cannot appear twice; promoting it moves it.
        browser.setSortField(.ping, atLevel: 0)
        XCTAssertEqual(browser.sortRules.map(\.field), [.ping])

        // Clearing a level drops everything below it.
        browser.setSortField(.map, atLevel: 1)
        browser.setSortField(.name, atLevel: 2)
        XCTAssertEqual(browser.sortRules.count, 3)
        browser.setSortField(nil, atLevel: 1)
        XCTAssertEqual(browser.sortRules.map(\.field), [.ping])
    }

    @MainActor
    func testChainIsCappedAtThreeLevels() {
        let browser = makeBrowser([])
        browser.sortRules = [
            ServerSortRule(field: .players, ascending: false),
            ServerSortRule(field: .ping, ascending: true),
            ServerSortRule(field: .mods, ascending: true),
        ]
        browser.applyTableSort([KeyPathComparator(\GameServer.map, order: .forward)])
        XCTAssertEqual(browser.sortRules.count, ServerBrowserModel.maxSortLevels)
        XCTAssertEqual(browser.sortRules.first?.field, .map)
    }

    @MainActor
    func testTableHeaderClickReplacesPrimaryAndKeepsTieBreaker() {
        let browser = makeBrowser([])
        browser.sortRules = [
            ServerSortRule(field: .players, ascending: false),
            ServerSortRule(field: .ping, ascending: true),
        ]

        // A header click hands back a single comparator; the tie-breakers must survive.
        browser.applyTableSort([KeyPathComparator(\GameServer.map, order: .forward)])

        XCTAssertEqual(browser.sortRules.first?.field, .map)
        XCTAssertTrue(browser.sortRules[0].ascending)
        XCTAssertEqual(browser.sortRules.map(\.field), [.map, .players, .ping])
    }

    @MainActor
    func testSecondaryIsIgnoredWhenItDuplicatesThePrimary() {
        let browser = makeBrowser([])
        browser.sortRules = [
            ServerSortRule(field: .players, ascending: false),
            ServerSortRule(field: .players, ascending: true),
        ]
        XCTAssertEqual(browser.sortOrder.count, 1)
    }

    /// Settings gaining a property must not discard the user's existing file.
    func testSettingsDecodeLenientlyWhenKeysAreMissing() throws {
        let json = Data(#"{"lastSection":"mods","queryConcurrency":32}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.lastSection, "mods")
        XCTAssertEqual(settings.queryConcurrency, 32)
        // Everything absent falls back to its default rather than throwing.
        XCTAssertTrue(settings.autoLoadModLists)
        XCTAssertEqual(settings.sortRules.map(\.field), [.players, .ping])
    }

    /// Settings written by a build that still had the SteamCMD route must still load, and
    /// must not leave mod installing pointed at a tool that is no longer there.
    func testSettingsFromASteamCMDEraFileStillInstallAutomatically() throws {
        let json = Data(#"""
        {"downloadRoute":"steamCMD","steamUsername":"astro","confirmAutomaticDownloads":true}
        """#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertTrue(settings.autoInstallServerMods)
    }

    @MainActor
    func testUnreachableServersSortLast() {
        let browser = makeBrowser([
            makeServer(host: "1.1.1.1", name: "Slow", players: 1, ping: .milliseconds(300)),
            makeServer(host: "2.2.2.2", name: "Dead", players: 1, ping: nil),
            makeServer(host: "3.3.3.3", name: "Fast", players: 1, ping: .milliseconds(20)),
        ])
        browser.sortRules = [ServerSortRule(field: .ping, ascending: true)]
        XCTAssertEqual(browser.visibleServers.map(\.name), ["Fast", "Slow", "Dead"])
    }
}

final class MultiPacketReassemblyTests: XCTestCase {
    /// Builds the two halves of a split reply the way a Source-engine server would.
    private func makeFragment(id: UInt32, total: UInt8, number: UInt8, payload: [UInt8]) -> Data {
        var writer = ByteWriter()
        writer.uint32(A2S.multiPacketHeader)
        writer.uint32(id)
        writer.byte(total)
        writer.byte(number)
        writer.uint16(1_248)  // split size
        writer.raw(payload)
        return writer.data
    }

    func testReassemblesOutOfOrderFragments() throws {
        var state = A2SSession.Reassembly()
        try A2SSession.ingest(
            makeFragment(id: 0x1234, total: 2, number: 1, payload: [0x03, 0x04]), into: &state
        )
        try A2SSession.ingest(
            makeFragment(id: 0x1234, total: 2, number: 0, payload: [0x01, 0x02]), into: &state
        )

        XCTAssertEqual(state.expected, 2)
        XCTAssertEqual(state.fragments.count, 2)

        var combined = Data()
        for fragment in state.fragments.sorted(by: { $0.index < $1.index }) {
            combined.append(fragment.payload)
        }
        XCTAssertEqual([UInt8](combined), [0x01, 0x02, 0x03, 0x04])
    }

    func testIgnoresDuplicatesAndForeignPacketIDs() throws {
        var state = A2SSession.Reassembly()
        try A2SSession.ingest(
            makeFragment(id: 0xAAAA, total: 2, number: 0, payload: [0x01]), into: &state
        )
        // Same fragment again, and one from an unrelated query sharing the socket.
        try A2SSession.ingest(
            makeFragment(id: 0xAAAA, total: 2, number: 0, payload: [0x01]), into: &state
        )
        try A2SSession.ingest(
            makeFragment(id: 0xBBBB, total: 2, number: 1, payload: [0x09]), into: &state
        )
        XCTAssertEqual(state.fragments.count, 1)
    }

    func testRejectsCompressedReplies() {
        var state = A2SSession.Reassembly()
        // The high bit of the packet id marks a bzip2-compressed reply.
        XCTAssertThrowsError(
            try A2SSession.ingest(
                makeFragment(id: 0x8000_0001, total: 2, number: 0, payload: [0x01]), into: &state
            )
        )
    }
}

final class GameExecutableDiscoveryTests: XCTestCase {
    private func makeGameDirectory(_ names: [String]) throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-exe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.createDirectory(
                at: root.appending(path: name), withIntermediateDirectories: true
            )
        }
        return root
    }

    /// On a case-insensitive volume `ArmA3.app` and `Arma3.app` are the same folder; it must
    /// only be reported once, under its real name.
    func testDeduplicatesCaseInsensitiveMatches() throws {
        let directory = try makeGameDirectory(["ArmA3.app"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = GameExecutable.discover(in: directory, container: .native)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].url.lastPathComponent, "ArmA3.app")
        XCTAssertEqual(found[0].kind, .macOSIntel)
    }

    func testFindsBothNativeBuilds() throws {
        let directory = try makeGameDirectory(["ArmA3.app", "ArmA3 AS Native.app"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = GameExecutable.discover(in: directory, container: .native)
        XCTAssertEqual(Set(found.map(\.kind)), [.macOSIntel, .macOSAppleSilicon])
    }

    func testFindsWindowsBinaries() throws {
        let directory = try makeGameDirectory(["arma3_x64.exe", "arma3.exe"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = GameExecutable.discover(
            in: directory,
            container: .crossover(bottle: "Steam", prefix: URL(filePath: "/prefix"))
        )
        XCTAssertEqual(Set(found.map(\.kind)), [.win64, .win32])
        // Windows binaries are not offered for a native install and vice versa.
        XCTAssertTrue(GameExecutable.discover(in: directory, container: .native).isEmpty)
    }
}

final class SteamClientServerListTests: XCTestCase {
    /// Fills a fixed-size C char array (imported into Swift as a tuple) from a String.
    private func fill<T>(_ target: inout T, with text: String) {
        withUnsafeMutableBytes(of: &target) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in text.utf8.enumerated() where index < raw.count - 1 {
                raw[index] = byte
            }
        }
    }

    private func makeRow(
        ip: UInt32 = 0xC000_020A,  // 192.0.2.10
        gamePort: UInt16 = 2_302,
        queryPort: UInt16 = 2_303,
        ping: Int32 = 45,
        players: Int32 = 30,
        bots: Int32 = 2,
        maxPlayers: Int32 = 64,
        password: Bool = false,
        name: String = "Test Server",
        map: String = "Altis",
        tags: String = "bt,r222,s7,vt,dt"
    ) -> ArmaMacSteamServer {
        var row = ArmaMacSteamServer()
        row.ip = ip
        row.gamePort = gamePort
        row.queryPort = queryPort
        row.ping = ping
        row.players = players
        row.botPlayers = bots
        row.maxPlayers = maxPlayers
        row.passwordProtected = password
        row.secure = true
        row.appID = 107_410
        fill(&row.name, with: name)
        fill(&row.map, with: map)
        fill(&row.gameTags, with: tags)
        return row
    }

    func testMapsSteamRowToGameServer() throws {
        let (address, server) = try XCTUnwrap(
            SteamClientServerList.makeServer(makeRow())
        )

        XCTAssertEqual(address.host, "192.0.2.10")
        XCTAssertEqual(address.gamePort, 2_302)
        XCTAssertEqual(address.queryPort, 2_303)
        XCTAssertEqual(server.name, "Test Server")
        XCTAssertEqual(server.map, "Altis")
        // Bots are excluded from the human player count, matching the A2S path.
        XCTAssertEqual(server.players, 28)
        XCTAssertEqual(server.maxPlayers, 64)
        XCTAssertEqual(server.ping, .milliseconds(45))
        // Arma's keyword string rides along in Steam's game tags.
        XCTAssertTrue(server.battlEye)
        XCTAssertTrue(server.verifySignatures)
        XCTAssertEqual(server.serverState, .playing)
        XCTAssertEqual(server.requiredVersion, "2.22")
    }

    /// Steam reports 2000 ms for servers it could not reach; that is not a real ping.
    func testDiscardsUnreachablePing() throws {
        let (_, server) = try XCTUnwrap(
            SteamClientServerList.makeServer(makeRow(ping: 2_000))
        )
        XCTAssertNil(server.ping)
        XCTAssertEqual(server.pingMilliseconds, .max)
    }

    func testDerivesQueryPortWhenSteamOmitsIt() throws {
        let (address, _) = try XCTUnwrap(
            SteamClientServerList.makeServer(makeRow(gamePort: 2_402, queryPort: 0))
        )
        XCTAssertEqual(address.queryPort, 2_403)
    }

    func testRejectsEmptyRows() {
        XCTAssertNil(SteamClientServerList.makeServer(makeRow(ip: 0)))
        XCTAssertNil(SteamClientServerList.makeServer(makeRow(gamePort: 0)))
    }

    func testReadsTruncatedCStringsSafely() throws {
        // A name that exactly fills the buffer must still terminate.
        let long = String(repeating: "A", count: 200)
        let (_, server) = try XCTUnwrap(SteamClientServerList.makeServer(makeRow(name: long)))
        XCTAssertEqual(server.name.count, 63)
    }
}

final class FieldOfViewTests: XCTestCase {
    /// Arma's stock profile values describe a 16:9 display.
    func testDefaultsMatchArmasOwnValues() {
        let fov = FieldOfView.arma3Default
        XCTAssertEqual(fov.fovTop, 0.75, accuracy: 0.0001)
        XCTAssertEqual(fov.aspectRatio, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(fov.verticalDegrees, 73.74, accuracy: 0.05)
        XCTAssertEqual(fov.horizontalDegrees, 106.26, accuracy: 0.05)
        XCTAssertEqual(fov.aspectRatioName, "16:9")
    }

    /// fovLeft is the tangent of half the horizontal FOV; fovTop follows from the ratio.
    func testHorizontalDegreesRoundTrip() {
        for degrees in [60.0, 75.0, 90.0, 106.26, 120.0] {
            let fov = FieldOfView(horizontalDegrees: degrees, aspectRatio: 16.0 / 9.0)
            XCTAssertEqual(fov.horizontalDegrees, degrees, accuracy: 0.01)
            XCTAssertEqual(fov.fovLeft, tan(degrees / 2 * .pi / 180), accuracy: 0.0001)
            XCTAssertEqual(fov.fovLeft / fov.fovTop, 16.0 / 9.0, accuracy: 0.001)
        }
    }

    func testVerticalDegreesRoundTrip() {
        let fov = FieldOfView(verticalDegrees: 70, aspectRatio: 21.0 / 9.0)
        XCTAssertEqual(fov.verticalDegrees, 70, accuracy: 0.01)
        XCTAssertEqual(fov.aspectRatio, 21.0 / 9.0, accuracy: 0.01)
    }

    /// The same horizontal FOV on a wider display must give a smaller vertical FOV.
    func testAspectRatioChangesVerticalNotHorizontal() {
        let wide = FieldOfView(horizontalDegrees: 100, aspectRatio: 32.0 / 9.0)
        let standard = FieldOfView(horizontalDegrees: 100, aspectRatio: 16.0 / 9.0)

        XCTAssertEqual(wide.horizontalDegrees, standard.horizontalDegrees, accuracy: 0.01)
        XCTAssertLessThan(wide.verticalDegrees, standard.verticalDegrees)
        XCTAssertLessThan(wide.fovTop, standard.fovTop)
    }

    func testClampsAbsurdValues() {
        XCTAssertEqual(
            FieldOfView(horizontalDegrees: 5, aspectRatio: 16.0 / 9.0).horizontalDegrees,
            FieldOfView.minimumHorizontal, accuracy: 0.01
        )
        XCTAssertEqual(
            FieldOfView(horizontalDegrees: 400, aspectRatio: 16.0 / 9.0).horizontalDegrees,
            FieldOfView.maximumHorizontal, accuracy: 0.01
        )
    }

    func testGuardsAgainstZeroAspect() {
        let fov = FieldOfView(horizontalDegrees: 90, aspectRatio: 0)
        XCTAssertEqual(fov.aspectRatio, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertTrue(fov.fovTop.isFinite)
    }
}

final class ArmaConfigEditorTests: XCTestCase {
    private let profile = """
    version=1;
    blood=1;
    fovTop=0.750000;
    fovLeft=1.333333;
    class Difficulties
    {
        class recruit
        {
            fovTop=9.999999;
            armor=1;
        };
    };
    lastMPGameMode=0;
    """

    func testReadsTopLevelKeys() {
        let editor = ArmaConfigEditor(text: profile)
        XCTAssertEqual(editor.doubleValue(for: "fovTop"), 0.75)
        XCTAssertEqual(editor.doubleValue(for: "fovLeft"), 1.333333)
        XCTAssertEqual(editor.intValue(for: "blood"), 1)
    }

    /// A key of the same name nested in a class must not be mistaken for the real one.
    func testIgnoresKeysInsideClasses() {
        var editor = ArmaConfigEditor(text: profile)
        XCTAssertEqual(editor.doubleValue(for: "fovTop"), 0.75)

        editor.setValue("0.600000", for: "fovTop")
        // The nested value is untouched.
        XCTAssertTrue(editor.text.contains("fovTop=9.999999;"))
        XCTAssertTrue(editor.text.contains("fovTop=0.600000;"))
        XCTAssertEqual(editor.doubleValue(for: "fovTop"), 0.6)
    }

    /// Everything the launcher does not manage has to survive byte for byte.
    func testPreservesUnrelatedContent() {
        var editor = ArmaConfigEditor(text: profile)
        editor.setValue("1.100000", for: "fovLeft")

        XCTAssertTrue(editor.text.contains("version=1;"))
        XCTAssertTrue(editor.text.contains("blood=1;"))
        XCTAssertTrue(editor.text.contains("class Difficulties"))
        XCTAssertTrue(editor.text.contains("armor=1;"))
        XCTAssertTrue(editor.text.contains("lastMPGameMode=0;"))
        XCTAssertEqual(editor.text.components(separatedBy: "fovLeft=").count - 1, 1)
    }

    func testAppendsMissingKey() {
        var editor = ArmaConfigEditor(text: "version=1;\n")
        editor.setValue(2_500, for: "viewDistance")
        XCTAssertEqual(editor.intValue(for: "viewDistance"), 2_500)
        XCTAssertTrue(editor.text.contains("version=1;"))
    }

    func testKeepsIndentationWhenReplacing() {
        var editor = ArmaConfigEditor(text: "    fovTop=0.750000;\n")
        editor.setValue("0.900000", for: "fovTop")
        XCTAssertTrue(editor.text.contains("    fovTop=0.900000;"))
    }

    func testStripsQuotesFromStringValues() {
        let editor = ArmaConfigEditor(text: #"playerName="Astro";"#)
        XCTAssertEqual(editor.value(for: "playerName"), "Astro")
    }

    /// Writing keeps a one-time backup of the original file.
    func testWriteKeepsBackup() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "Test.Arma3Profile")
        try Data(profile.utf8).write(to: url)

        var editor = try ArmaConfigEditor(contentsOf: url)
        editor.setValue("0.500000", for: "fovTop")
        try editor.write(to: url)

        let backup = url.appendingPathExtension("armamac-bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        let restored = try ArmaConfigEditor(contentsOf: backup)
        XCTAssertEqual(restored.doubleValue(for: "fovTop"), 0.75)

        let saved = try ArmaConfigEditor(contentsOf: url)
        XCTAssertEqual(saved.doubleValue(for: "fovTop"), 0.5)
    }
}

final class ArmaProfileManagementTests: XCTestCase {
    /// Arma percent-encodes anything outside A–Z a–z 0–9 _ - in profile file names.
    func testFileNameEncoding() {
        XCTAssertEqual(ArmaProfileLocator.fileName(for: "Astro"), "Astro")
        XCTAssertEqual(ArmaProfileLocator.fileName(for: "Alpha Team"), "Alpha%20Team")
        XCTAssertEqual(ArmaProfileLocator.fileName(for: "recon-1_b"), "recon-1_b")
        XCTAssertEqual(ArmaProfileLocator.fileName(for: "Zeus!"), "Zeus%21")
    }

    func testFileNameRoundTrip() {
        for name in ["Astro", "Alpha Team", "Zeus!", "3rd Ranger Bn."] {
            let encoded = ArmaProfileLocator.fileName(for: name)
            XCTAssertEqual(ArmaProfileLocator.displayName(fromFileName: encoded), name)
        }
    }

    func testDisplayNameMarksTheDefault() {
        let url = URL(filePath: "/tmp/Astro.Arma3Profile")
        let normal = ArmaProfile(profileURL: url, configURL: nil, name: "Astro", isDefault: false)
        let fallback = ArmaProfile(profileURL: url, configURL: nil, name: "Astro", isDefault: true)
        XCTAssertEqual(normal.displayName, "Astro")
        XCTAssertEqual(fallback.displayName, "Astro (default)")
    }

    /// A new profile starts from Arma's stock FOV, so it is immediately editable.
    func testStarterProfileHasReadableFOV() throws {
        let editor = ArmaConfigEditor(text: """
        version=1;
        fovTop=0.750000;
        fovLeft=1.333333;
        """)
        let fov = FieldOfView(
            fovTop: try XCTUnwrap(editor.doubleValue(for: "fovTop")),
            fovLeft: try XCTUnwrap(editor.doubleValue(for: "fovLeft"))
        )
        XCTAssertEqual(fov, .arma3Default)
    }
}

@MainActor
final class GameSettingsModelTests: XCTestCase {
    func testNameAvailabilityIsCaseInsensitive() {
        let model = GameSettingsModel()
        XCTAssertFalse(model.isNameAvailable(""))
        XCTAssertFalse(model.isNameAvailable("   "))
        // With no profiles loaded, any real name is free.
        XCTAssertTrue(model.isNameAvailable("Alpha"))
    }

    /// The FOV shown must round-trip through the tangents Arma stores.
    func testCurrentFOVFollowsTheSliderAndAspect() {
        let model = GameSettingsModel()
        model.horizontalFOV = 90
        model.aspectRatio = 21.0 / 9.0

        XCTAssertEqual(model.currentFOV.horizontalDegrees, 90, accuracy: 0.01)
        XCTAssertEqual(model.currentFOV.aspectRatio, 21.0 / 9.0, accuracy: 0.01)
        XCTAssertFalse(model.isDefaultFOV)

        model.resetFOVToDefault()
        XCTAssertTrue(model.isDefaultFOV)
        XCTAssertEqual(model.currentFOV.fovTop, 0.75, accuracy: 0.0001)
    }

    func testTerrainQualityMapsToNearestArmaGrid() {
        XCTAssertEqual(GameSettingsModel.TerrainQuality.closest(to: 12.5), .standard)
        XCTAssertEqual(GameSettingsModel.TerrainQuality.closest(to: 3.0), .ultra)
        XCTAssertEqual(GameSettingsModel.TerrainQuality.closest(to: 40), .veryLow)
    }
}

@MainActor
final class ModLibraryUpdateTests: XCTestCase {
    /// A mod is outdated only when Steam's update time is newer than the local meta stamp.
    func testOutdatedDetectionUsesFiletimeTicks() {
        let model = ModLibraryModel()

        // 2024-01-01 as Windows FILETIME ticks (100 ns since 1601).
        let localDate = Date(timeIntervalSince1970: 1_704_067_200)
        let ticks = UInt64((localDate.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)

        let mod = Mod(
            path: URL(filePath: "/tmp/450814997"),
            origin: .workshop,
            publishedFileID: 450_814_997,
            name: "CBA_A3",
            metaTimestamp: ticks,
            lastScanned: .now
        )

        // Without Workshop details there is nothing to compare against.
        XCTAssertFalse(model.hasUpdate(mod))
    }

    func testOutdatedListIsEmptyWithoutDetails() {
        XCTAssertTrue(ModLibraryModel().outdatedMods.isEmpty)
    }
}

@MainActor
final class ServerBrowserScopeTests: XCTestCase {
    private func makeServer(_ host: String, modsLoaded: Bool) -> GameServer {
        var server = GameServer(address: ServerAddress(host: host, gamePort: 2_302))
        server.name = host
        server.players = 5
        server.maxPlayers = 40
        server.modsLoaded = modsLoaded
        return server
    }

    /// Derived values are cached, so every mutation path has to refresh them.
    func testUpsertRefreshesDerivedState() {
        let browser = ServerBrowserModel()
        XCTAssertEqual(browser.visibleServers.count, 0)
        XCTAssertEqual(browser.totalPlayers, 0)

        browser.upsert(makeServer("1.1.1.1", modsLoaded: true))
        XCTAssertEqual(browser.visibleServers.count, 1)
        XCTAssertEqual(browser.totalPlayers, 5)
        XCTAssertEqual(browser.responsiveCount, 1)

        browser.upsert(makeServer("2.2.2.2", modsLoaded: false))
        XCTAssertEqual(browser.visibleServers.count, 2)
        XCTAssertEqual(browser.totalPlayers, 10)
    }

    /// Changing the filter must re-derive without needing a new query.
    func testFilterChangeRebuildsCache() {
        let browser = ServerBrowserModel()
        browser.upsert(makeServer("1.1.1.1", modsLoaded: true))
        XCTAssertEqual(browser.visibleServers.count, 1)

        browser.filter.searchText = "nothing matches"
        XCTAssertEqual(browser.visibleServers.count, 0)

        browser.filter.searchText = ""
        XCTAssertEqual(browser.visibleServers.count, 1)
    }

    func testKnownMapsTracksTheServerSet() {
        let browser = ServerBrowserModel()
        var altis = makeServer("1.1.1.1", modsLoaded: true)
        altis.map = "Altis"
        var malden = makeServer("2.2.2.2", modsLoaded: true)
        malden.map = "Malden"

        browser.upsert(altis)
        browser.upsert(malden)
        XCTAssertEqual(browser.knownMaps, ["Altis", "Malden"])
    }
}

final class ArmaProfileRenameTests: XCTestCase {
    private let locator = ArmaProfileLocator()

    private func makeRoot() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeProfile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("version=1;\nfovTop=0.750000;\n".utf8).write(to: url)
    }

    /// A profile in its own folder renames both the file and the folder.
    func testRenamesOwnFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appending(path: "Alpha/Alpha.Arma3Profile")
        try writeProfile(at: url)
        let profile = ArmaProfile(profileURL: url, configURL: nil, name: "Alpha", isDefault: false)

        let renamed = try locator.renameProfile(profile, to: "Bravo Team")

        XCTAssertEqual(renamed.name, "Bravo Team")
        XCTAssertEqual(renamed.profileURL.lastPathComponent, "Bravo%20Team.Arma3Profile")
        XCTAssertEqual(
            renamed.profileURL.deletingLastPathComponent().lastPathComponent, "Bravo%20Team"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: renamed.profileURL.path(percentEncoded: false))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Alpha").path(percentEncoded: false)
            )
        )
    }

    /// A loose profile sitting in a shared folder must rename only itself. Renaming used to
    /// move the containing folder, dragging every other profile in it along.
    func testLooseProfileDoesNotMoveItsSharedFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let shared = root.appending(path: "Arma 3 - Other Profiles")
        let loose = shared.appending(path: "Loose.Arma3Profile")
        let neighbour = shared.appending(path: "Neighbour/Neighbour.Arma3Profile")
        try writeProfile(at: loose)
        try writeProfile(at: neighbour)

        let profile = ArmaProfile(
            profileURL: loose, configURL: nil, name: "Loose", isDefault: false
        )
        let renamed = try locator.renameProfile(profile, to: "Renamed")

        // The file moved; the shared folder and its other profile stayed put.
        XCTAssertEqual(
            SteamLocator.pathKey(renamed.profileURL.deletingLastPathComponent()),
            SteamLocator.pathKey(shared)
        )
        XCTAssertEqual(renamed.profileURL.lastPathComponent, "Renamed.Arma3Profile")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: neighbour.path(percentEncoded: false))
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: shared.path(percentEncoded: false))
        )
    }

    func testRejectsNameAlreadyOnDisk() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeProfile(at: root.appending(path: "Alpha/Alpha.Arma3Profile"))
        try writeProfile(at: root.appending(path: "Bravo/Bravo.Arma3Profile"))

        let alpha = ArmaProfile(
            profileURL: root.appending(path: "Alpha/Alpha.Arma3Profile"),
            configURL: nil, name: "Alpha", isDefault: false
        )
        XCTAssertThrowsError(try locator.renameProfile(alpha, to: "Bravo"))
        // The original survives a rejected rename.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: alpha.profileURL.path(percentEncoded: false))
        )
    }

    func testRejectsEmptyName() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Alpha/Alpha.Arma3Profile")
        try writeProfile(at: url)
        let profile = ArmaProfile(profileURL: url, configURL: nil, name: "Alpha", isDefault: false)
        XCTAssertThrowsError(try locator.renameProfile(profile, to: "   "))
    }
}

@MainActor
final class LoadOrderUndoTests: XCTestCase {
    func testReplacingRemembersThePreviousOrder() {
        let library = ModLibraryModel()
        library.enabledIDs = ["a", "b", "c"]
        XCTAssertFalse(library.canRestorePreviousOrder)

        library.replaceEnabled(with: ["x", "y"], source: "Server One")
        XCTAssertEqual(library.enabledIDs, ["x", "y"])
        XCTAssertTrue(library.canRestorePreviousOrder)
        XCTAssertEqual(library.previousOrderSource, "Server One")

        library.restorePreviousOrder()
        XCTAssertEqual(library.enabledIDs, ["a", "b", "c"])
    }

    /// Restoring is itself undoable, so a mis-click is recoverable.
    func testRestoreIsReversible() {
        let library = ModLibraryModel()
        library.enabledIDs = ["a"]
        library.replaceEnabled(with: ["b"], source: "Server")
        library.restorePreviousOrder()
        XCTAssertEqual(library.enabledIDs, ["a"])

        library.restorePreviousOrder()
        XCTAssertEqual(library.enabledIDs, ["b"])
    }

    /// Replacing with an identical order is not a change worth remembering.
    func testIdenticalReplacementIsIgnored() {
        let library = ModLibraryModel()
        library.enabledIDs = ["a", "b"]
        library.replaceEnabled(with: ["a", "b"], source: "Server")
        XCTAssertFalse(library.canRestorePreviousOrder)
    }

    func testReplacementDropsDuplicates() {
        let library = ModLibraryModel()
        library.replaceEnabled(with: ["a", "a", "b"], source: "Server")
        XCTAssertEqual(library.enabledIDs, ["a", "b"])
    }
}

@MainActor
final class ServerSearchTests: XCTestCase {
    private func makeServer(
        host: String, name: String, map: String = "Altis", mods: [String] = []
    ) -> GameServer {
        var server = GameServer(address: ServerAddress(host: host, gamePort: 2_302))
        server.name = name
        server.map = map
        server.players = 10
        server.maxPlayers = 40
        server.mods = mods.enumerated().map {
            ServerMod(publishedFileID: UInt64($0.offset + 1), name: $0.element, hash: 0)
        }
        server.modsLoaded = true
        return server
    }

    /// Once mod lists are loaded, searching should reach them too.
    func testSearchMatchesModNames() {
        let browser = ServerBrowserModel()
        browser.upsert(makeServer(host: "1.1.1.1", name: "Alpha", mods: ["CBA_A3", "ace"]))
        browser.upsert(makeServer(host: "2.2.2.2", name: "Bravo", mods: ["CUP Weapons"]))

        browser.filter.searchText = "ace"
        XCTAssertEqual(browser.visibleServers.map(\.name), ["Alpha"])

        browser.filter.searchText = "cup"
        XCTAssertEqual(browser.visibleServers.map(\.name), ["Bravo"])
    }

    func testSearchStillMatchesNameMapAndHost() {
        let browser = ServerBrowserModel()
        browser.upsert(makeServer(host: "203.0.113.9", name: "Zeus Night", map: "Malden"))

        for needle in ["zeus", "malden", "203.0.113"] {
            browser.filter.searchText = needle
            XCTAssertEqual(browser.visibleServers.count, 1, "failed for \(needle)")
        }

        browser.filter.searchText = "nothing"
        XCTAssertTrue(browser.visibleServers.isEmpty)
    }
}

@MainActor
final class GameSettingsProfileSelectionTests: XCTestCase {
    private func makeProfile(_ name: String, config: URL?) -> ArmaProfile {
        ArmaProfile(
            profileURL: URL(filePath: "/tmp/\(name).Arma3Profile"),
            configURL: config,
            name: name,
            isDefault: false
        )
    }

    /// Arma writing Arma3.cfg changes the struct but not the profile; the selection must
    /// follow the file, not struct equality.
    func testSelectionSurvivesConfigAppearing() {
        let before = makeProfile("Alpha", config: nil)
        let after = makeProfile("Alpha", config: URL(filePath: "/tmp/Arma3.cfg"))

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.profileURL, after.profileURL)
        // The refresh keys off profileURL, so the same file is still the same profile.
        XCTAssertTrue([after].contains { $0.profileURL == before.profileURL })
    }
}

final class ModScannerDeduplicationTests: XCTestCase {
    /// After a modded launch the same mod exists twice on disk: in the workshop folder and
    /// as a symlink in `!Workshop`. It must be listed once.
    func testSymlinkedWorkshopModIsNotListedTwice() throws {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-dedup-\(UUID().uuidString)")
        let library = SteamLibrary(root: root, container: .native)
        let gameDirectory = library.common.appending(path: "Arma 3")
        let workshopMod = library.workshopContent.appending(path: "450814997")

        try fileManager.createDirectory(
            at: workshopMod.appending(path: "addons"), withIntermediateDirectories: true
        )
        try #"name = "CBA_A3";"#.write(
            to: workshopMod.appending(path: "mod.cpp"), atomically: true, encoding: .utf8
        )
        try "publishedid = 450814997;".write(
            to: workshopMod.appending(path: "meta.cpp"), atomically: true, encoding: .utf8
        )

        let linkRoot = gameDirectory.appending(path: "!Workshop")
        try fileManager.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: linkRoot.appending(path: "@CBA_A3"), withDestinationURL: workshopMod
        )
        defer { try? fileManager.removeItem(at: root) }

        let installation = GameInstallation(
            directory: gameDirectory, library: library, executables: []
        )
        let mods = ModScanner().scan(installation: installation)

        XCTAssertEqual(mods.count, 1)
        XCTAssertEqual(mods.first?.origin, .workshop)
        XCTAssertEqual(mods.first?.publishedFileID, 450_814_997)
        // Duplicate SwiftUI identities were the other symptom.
        XCTAssertEqual(Set(mods.map(\.id)).count, mods.count)
    }

    /// A hand-made link in `!Workshop` whose target is not a workshop item still shows up.
    func testLooseLinkedModStillAppears() throws {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-dedup2-\(UUID().uuidString)")
        let library = SteamLibrary(root: root, container: .native)
        let gameDirectory = library.common.appending(path: "Arma 3")
        let external = root.appending(path: "elsewhere/@Custom")

        try fileManager.createDirectory(
            at: external.appending(path: "addons"), withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: library.workshopContent, withIntermediateDirectories: true
        )
        let linkRoot = gameDirectory.appending(path: "!Workshop")
        try fileManager.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: linkRoot.appending(path: "@Custom"), withDestinationURL: external
        )
        defer { try? fileManager.removeItem(at: root) }

        let installation = GameInstallation(
            directory: gameDirectory, library: library, executables: []
        )
        let mods = ModScanner().scan(installation: installation)
        XCTAssertEqual(mods.count, 1)
        XCTAssertEqual(mods.first?.name, "@Custom")
    }
}

final class ModLinkerPruneTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var installation: GameInstallation
        var linkRoot: URL
        var workshopMod: URL
        var external: URL
    }

    private func makeFixture() throws -> Fixture {
        let fileManager = FileManager.default
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "armamac-prune-\(UUID().uuidString)")
        let library = SteamLibrary(root: root, container: .native)
        let gameDirectory = library.common.appending(path: "Arma 3")
        let workshopMod = library.workshopContent.appending(path: "450814997")
        let external = root.appending(path: "elsewhere/@Custom")

        for url in [workshopMod, external] {
            try fileManager.createDirectory(
                at: url.appending(path: "addons"), withIntermediateDirectories: true
            )
        }
        let linkRoot = gameDirectory.appending(path: "!Workshop")
        try fileManager.createDirectory(at: linkRoot, withIntermediateDirectories: true)

        return Fixture(
            root: root,
            installation: GameInstallation(
                directory: gameDirectory, library: library, executables: []
            ),
            linkRoot: linkRoot,
            workshopMod: workshopMod,
            external: external
        )
    }

    /// A link the user made by hand points outside the workshop folder, so it is not ours
    /// to delete — pruning used to remove it on every launch.
    func testKeepsLinksPointingOutsideTheWorkshop() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fileManager = FileManager.default

        let handMade = fixture.linkRoot.appending(path: "@Custom")
        let ours = fixture.linkRoot.appending(path: "@CBA_A3")
        try fileManager.createSymbolicLink(at: handMade, withDestinationURL: fixture.external)
        try fileManager.createSymbolicLink(at: ours, withDestinationURL: fixture.workshopMod)

        let removed = ModLinker(installation: fixture.installation).pruneLinks(keeping: [])

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: handMade.path(percentEncoded: false)))
        XCTAssertNil(
            try? fileManager.destinationOfSymbolicLink(atPath: ours.path(percentEncoded: false))
        )
    }

    /// Dangling links are always cleaned up, wherever they pointed.
    func testRemovesDanglingLinks() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fileManager = FileManager.default

        let dangling = fixture.linkRoot.appending(path: "@Gone")
        try fileManager.createSymbolicLink(
            at: dangling, withDestinationURL: fixture.root.appending(path: "missing/@Gone")
        )

        let removed = ModLinker(installation: fixture.installation).pruneLinks(keeping: [])
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: dangling.path(percentEncoded: false)))
    }

    func testNeverTouchesRealFolders() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let real = fixture.linkRoot.appending(path: "@Handmade")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)

        _ = ModLinker(installation: fixture.installation).pruneLinks(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.path(percentEncoded: false)))
    }
}

final class WorkshopProgressTests: XCTestCase {
    private typealias Item = WorkshopDownloader.Item

    /// Steam downloads several mods at once, so progress must aggregate bytes rather than
    /// follow whichever item happened to be polled last.
    func testProgressAggregatesBytes() {
        let items = [
            Item(id: 1, name: "A", state: .downloading, expectedBytes: 100, downloadedBytes: 50),
            Item(id: 2, name: "B", state: .downloading, expectedBytes: 300, downloadedBytes: 150),
        ]
        XCTAssertEqual(WorkshopDownloader.downloadedBytes(of: items), 200)
        XCTAssertEqual(WorkshopDownloader.expectedBytes(of: items), 400)
        XCTAssertEqual(WorkshopDownloader.progress(of: items), 0.5, accuracy: 0.001)
    }

    /// Without sizes it falls back to counting finished items.
    func testProgressFallsBackToItemCount() {
        let items = [
            Item(id: 1, name: "A", state: .finished(nil)),
            Item(id: 2, name: "B", state: .downloading),
        ]
        XCTAssertEqual(WorkshopDownloader.expectedBytes(of: items), 0)
        XCTAssertEqual(WorkshopDownloader.progress(of: items), 0.5, accuracy: 0.001)
    }

    func testProgressIsZeroWithNoItems() {
        XCTAssertEqual(WorkshopDownloader.progress(of: []), 0)
    }

    /// Steam can report more bytes fetched than the API's advertised size.
    func testProgressNeverExceedsOne() {
        let items = [
            Item(id: 1, name: "A", state: .downloading, expectedBytes: 100, downloadedBytes: 250)
        ]
        XCTAssertEqual(WorkshopDownloader.progress(of: items), 1.0, accuracy: 0.001)
    }

    /// A failed item still counts as finished for the bar; the queue shows why.
    func testFailedItemsCountAsComplete() {
        let items = [
            Item(id: 1, name: "A", state: .failed("nope")),
            Item(id: 2, name: "B", state: .queued),
        ]
        XCTAssertEqual(WorkshopDownloader.progress(of: items), 0.5, accuracy: 0.001)
    }
}

final class ArmaConfigLineEndingTests: XCTestCase {
    /// Arma writes CRLF on Windows, so profiles inside a Wine prefix look like this.
    /// Values used to parse as "0.750000;\r" — semicolon never stripped, number never read,
    /// and the setting silently fell back to its default.
    private let crlfProfile = "version=1;\r\nfovTop=0.750000;\r\nfovLeft=1.333333;\r\n"

    func testReadsValuesFromCRLFFiles() {
        let editor = ArmaConfigEditor(text: crlfProfile)
        XCTAssertEqual(editor.doubleValue(for: "fovTop"), 0.75)
        XCTAssertEqual(editor.doubleValue(for: "fovLeft"), 1.333333)
        XCTAssertEqual(editor.intValue(for: "version"), 1)
    }

    /// A CRLF file must stay CRLF after editing, or Arma sees a mangled profile.
    func testPreservesCRLFOnWrite() {
        var editor = ArmaConfigEditor(text: crlfProfile)
        editor.setValue("0.600000", for: "fovTop")

        XCTAssertTrue(editor.text.contains("fovTop=0.600000;\r\n"))
        XCTAssertFalse(editor.text.contains("\n\n"))
        // Every newline in the output is part of a CRLF pair.
        XCTAssertEqual(
            editor.text.components(separatedBy: "\r\n").count,
            editor.text.components(separatedBy: "\n").count
        )
    }

    func testLeavesLFFilesAlone() {
        var editor = ArmaConfigEditor(text: "fovTop=0.750000;\nfovLeft=1.333333;\n")
        editor.setValue("0.600000", for: "fovTop")
        XCTAssertFalse(editor.text.contains("\r"))
        XCTAssertEqual(editor.doubleValue(for: "fovTop"), 0.6)
    }

    /// The round trip that matters: read a CRLF profile, change the FOV, read it back.
    func testCRLFRoundTripKeepsTheRealValue() throws {
        var editor = ArmaConfigEditor(text: crlfProfile)
        let loaded = FieldOfView(
            fovTop: try XCTUnwrap(editor.doubleValue(for: "fovTop")),
            fovLeft: try XCTUnwrap(editor.doubleValue(for: "fovLeft"))
        )
        XCTAssertEqual(loaded, .arma3Default)

        let wide = FieldOfView(horizontalDegrees: 120, aspectRatio: 16.0 / 9.0)
        editor.setValue(wide.fovTopText, for: "fovTop")
        editor.setValue(wide.fovLeftText, for: "fovLeft")

        let reread = ArmaConfigEditor(text: editor.text)
        XCTAssertEqual(reread.doubleValue(for: "fovTop") ?? 0, wide.fovTop, accuracy: 0.0001)
        XCTAssertEqual(reread.doubleValue(for: "fovLeft") ?? 0, wide.fovLeft, accuracy: 0.0001)
    }
}

final class FieldOfViewPresetTests: XCTestCase {
    func testPresetsAreWithinTheSupportedRange() {
        for preset in FieldOfView.presets {
            XCTAssertGreaterThanOrEqual(preset.horizontal, FieldOfView.minimumHorizontal)
            XCTAssertLessThanOrEqual(preset.horizontal, FieldOfView.maximumHorizontal)
        }
    }

    func testDefaultPresetMatchesArmasOwnValue() throws {
        let stock = try XCTUnwrap(FieldOfView.presets.first { $0.name == "Default" })
        let fov = FieldOfView(horizontalDegrees: stock.horizontal, aspectRatio: 16.0 / 9.0)
        XCTAssertEqual(fov.fovTop, FieldOfView.arma3Default.fovTop, accuracy: 0.0001)
    }
}

final class LaunchFailureReportingTests: XCTestCase {
    private func makePlan(container: RuntimeContainer, executable: GameExecutable) -> LaunchPlan {
        let root = URL(filePath: "/Games/Steam")
        let installation = GameInstallation(
            directory: root.appending(path: "steamapps/common/Arma 3"),
            library: SteamLibrary(root: root, container: container),
            executables: [executable]
        )
        return LaunchPlan(
            installation: installation, executable: executable, arguments: ["-skipIntro"]
        )
    }

    /// Launching a bogus Wine install must fail loudly. Which error depends on the machine
    /// — with CrossOver installed the runtime check passes and the spawn fails instead —
    /// so the property under test is that it never silently "succeeds".
    func testBrokenWineInstallFailsLoudly() {
        let plan = makePlan(
            container: .crossover(bottle: "Steam", prefix: URL(filePath: "/nope")),
            executable: GameExecutable(
                url: URL(filePath: "/nope/arma3_x64.exe"), kind: .win64
            )
        )
        XCTAssertThrowsError(try GameLauncher().launch(plan: plan, viaSteam: false)) { error in
            guard let launchError = error as? GameLauncher.LaunchError else {
                return XCTFail("expected a LaunchError, got \(error)")
            }
            XCTAssertFalse(launchError.localizedDescription.isEmpty)
        }
    }

    /// Every launch error must carry a readable reason — these strings are what the user
    /// sees in the alert.
    func testErrorsAreDescribed() {
        let errors: [GameLauncher.LaunchError] = [
            .noInstallation, .noExecutable, .noWineRuntime, .launchFailed("disk is on fire"),
        ]
        for error in errors {
            let description = error.localizedDescription
            XCTAssertFalse(description.isEmpty)
            XCTAssertFalse(description.contains("LaunchError"))
        }
        XCTAssertTrue(
            GameLauncher.LaunchError.launchFailed("disk is on fire")
                .localizedDescription.contains("disk is on fire")
        )
    }

    /// A plan with no mods must not emit a -mod= argument at all.
    func testVanillaPlanHasNoModArgument() throws {
        let root = URL(filePath: "/Games/Steam")
        let directory = root.appending(path: "steamapps/common/Arma 3")
        let installation = GameInstallation(
            directory: directory,
            library: SteamLibrary(root: root, container: .native),
            executables: [
                GameExecutable(url: directory.appending(path: "ArmA3.app"), kind: .macOSIntel)
            ]
        )
        let plan = try GameLauncher().makePlan(
            installation: installation,
            mods: [],
            options: LaunchOptions(),
            connect: nil,
            linkedMods: [:]
        )
        XCTAssertFalse(plan.arguments.contains { $0.hasPrefix("-mod=") })
        XCTAssertTrue(plan.displayCommand.contains("ArmA3.app"))
    }
}

final class ServerModsetExportTests: XCTestCase {
    /// A server's modset exports to the same format the official launcher imports, so it
    /// can be shared with players who do not have the mods yet.
    func testServerModsetRoundTrips() {
        let mods = [
            ServerMod(publishedFileID: 450_814_997, name: "CBA_A3", hash: 0),
            ServerMod(publishedFileID: 463_939_057, name: "ace & friends", hash: 0),
            ServerMod(publishedFileID: 333_310_405, name: "", hash: 0),
        ]
        let html = PresetHTML.export(name: "Unit Night", serverMods: mods)
        let parsed = PresetHTML.parse(html: html)

        XCTAssertEqual(parsed.name, "Unit Night")
        XCTAssertEqual(parsed.mods.count, 3)
        XCTAssertEqual(parsed.mods.map(\.publishedFileID), [450_814_997, 463_939_057, 333_310_405])
        // Ampersands must survive the HTML round trip.
        XCTAssertEqual(parsed.mods[1].name, "ace & friends")
        // An unnamed mod still gets something readable.
        XCTAssertTrue(parsed.mods[2].name.contains("333310405"))
    }

    func testEmptyModsetProducesAValidDocument() {
        let html = PresetHTML.export(name: "Vanilla", serverMods: [])
        let parsed = PresetHTML.parse(html: html)
        XCTAssertEqual(parsed.name, "Vanilla")
        XCTAssertTrue(parsed.mods.isEmpty)
    }
}

final class ServerPlayerLoadingTests: XCTestCase {
    /// The background mod sweep marks servers as `modsLoaded` without asking for players,
    /// so the two flags must stay independent — keying the inspector off the wrong one left
    /// the player list permanently empty.
    func testModsLoadedDoesNotImplyPlayersLoaded() {
        var server = GameServer(address: ServerAddress(host: "1.1.1.1", gamePort: 2_302))
        server.modsLoaded = true
        XCTAssertFalse(server.playersLoaded)

        server.playersLoaded = true
        XCTAssertTrue(server.playersLoaded)
    }
}

final class CreatorDLCMappingTests: XCTestCase {
    /// Arma loads Creator DLC by folder name, so every one the decoder can name must also
    /// have a folder. Matching on the display name never worked: a server advertising
    /// "S.O.G. Prairie Fire" has to resolve to the `vn` folder on disk.
    func testEveryNamedCreatorDLCHasAFolder() {
        for (appID, name) in ArmaServerBrowserProtocol.creatorDLCNames {
            XCTAssertNotNil(
                ArmaServerBrowserProtocol.creatorDLCFolders[appID],
                "no folder mapped for \(name) (\(appID))"
            )
        }
    }

    /// Those folders must be ones the scanner recognises as official content, otherwise the
    /// mod would never be listed to match against.
    func testFoldersAreRecognisedAsOfficialContent() {
        for folder in ArmaServerBrowserProtocol.creatorDLCFolders.values {
            XCTAssertTrue(
                ModScanner.officialModFolders.contains(folder.lowercased()),
                "scanner does not treat \(folder) as official content"
            )
        }
    }

    func testFoldersAreUnique() {
        let folders = ArmaServerBrowserProtocol.creatorDLCFolders.values.map { $0.lowercased() }
        XCTAssertEqual(Set(folders).count, folders.count)
    }

    /// The decoder emits Creator DLC with the ids these tables are keyed by.
    func testDecoderProducesMappableCreatorDLC() throws {
        var writer = ByteWriter()
        writer.byte(3)
        writer.byte(0)
        writer.uint16(0)
        writer.byte(0)
        writer.byte(0)
        writer.byte(1)                  // one "mod" entry
        writer.uint32(0xAABB_CCDD)      // hash
        writer.byte(19)                 // Creator DLC marker
        writer.uint32(1_227_700)        // S.O.G. Prairie Fire
        writer.byte(0)                  // no signatures

        let payload = try ArmaServerBrowserProtocol.decodeMessage(writer.bytes)
        let dlc = try XCTUnwrap(payload.dlcs.first { $0.isCreatorDLC })
        XCTAssertEqual(dlc.appID, 1_227_700)
        XCTAssertEqual(ArmaServerBrowserProtocol.creatorDLCFolders[dlc.appID], "vn")
    }
}

@MainActor
final class PendingModOrderTests: XCTestCase {
    /// Mods that are not installed yet keep their workshop id in the load order, so the
    /// entry resolves by itself once the download lands. Presets already did this; a
    /// collection with missing mods used to end up with no order at all.
    func testUninstalledEntriesSurviveAsWorkshopIDs() {
        let library = ModLibraryModel()
        library.replaceEnabled(with: ["450814997", "463939057"], source: "collection")

        XCTAssertEqual(library.enabledIDs, ["450814997", "463939057"])
        // Nothing installed, so nothing resolves — but the order is remembered.
        XCTAssertTrue(library.enabledMods.isEmpty)
        XCTAssertEqual(library.missingEnabledIDs.count, 2)
    }

    /// A Mod's identity is its workshop id, so a placeholder becomes the real entry with
    /// no extra bookkeeping once the mod is scanned.
    func testWorkshopIDPlaceholderMatchesTheInstalledMod() {
        let mod = Mod(
            path: URL(filePath: "/tmp/450814997"),
            origin: .workshop,
            publishedFileID: 450_814_997,
            name: "CBA_A3",
            lastScanned: .now
        )
        XCTAssertEqual(mod.id, "450814997")
    }
}
