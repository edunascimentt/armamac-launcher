import Foundation

/// Parser for the comma-separated tag string Arma 3 puts in the A2S_INFO `keywords` field,
/// e.g. `bt,r160,n1490,s7,i1,mf,lf,vt,dt,ttdm,g65545,h9fe4bb59,f0,c0-0,pw,e0,j0,k0`.
///
/// This is the cheap source of filter data: it arrives with the info query, so the browser
/// can filter on BattlEye/signatures/state without a rules round trip.
///
/// Reference: https://community.bistudio.com/wiki/Arma_3:_STEAMWORKSquery
struct ArmaKeywords: Sendable {
    var battlEye = false
    var requiredVersion: String = ""
    var requiredBuild: UInt32 = 0
    var serverState: ServerState = .none
    var difficulty: UInt8 = 0
    var equalModRequired = false
    var locked = false
    var verifySignatures = false
    var dedicated = false
    var gameType = ""
    var language: UInt32 = 0
    var longitude: Int32 = 0
    var latitude: Int32 = 0
    var platform = ""
    var loadedContentHash = ""
    var country = ""
    var timeLeft: Duration?
    var param1: UInt8 = 0
    var param2: UInt8 = 0
    var allowedFilePatching = false
    var island = ""
    var unknown: [String] = []

    init(_ keywords: String?) {
        guard let keywords, !keywords.isEmpty else { return }
        for tag in keywords.split(separator: ",", omittingEmptySubsequences: true) {
            parse(tag: String(tag))
        }
    }

    private mutating func parse(tag: String) {
        guard let marker = tag.first, tag.count > 1 else {
            if !tag.isEmpty { unknown.append(tag) }
            return
        }
        let value = String(tag.dropFirst())

        switch marker {
        case "b": battlEye = Self.bool(value)
        case "r": requiredVersion = Self.versionString(value)
        case "n": requiredBuild = UInt32(value) ?? 0
        case "s": serverState = ServerState(rawValue: Int(value) ?? 0) ?? .none
        case "i": difficulty = UInt8(value) ?? 0
        case "m": equalModRequired = Self.bool(value)
        case "l": locked = Self.bool(value)
        case "v": verifySignatures = Self.bool(value)
        case "d": dedicated = Self.bool(value)
        case "t": gameType = value
        case "g": language = UInt32(value) ?? 0
        case "c": (longitude, latitude) = Self.coordinates(value)
        case "p": platform = value
        case "h": loadedContentHash = value
        case "o": country = value.uppercased()
        case "e": timeLeft = Double(value).map { Duration.seconds($0 * 60) }
        case "j": param1 = UInt8(value) ?? 0
        case "k": param2 = UInt8(value) ?? 0
        case "f": allowedFilePatching = Self.bool(value)
        case "y": island = value
        default: unknown.append(tag)
        }
    }

    /// Tags encode booleans as `t`/`f` or `1`/`0` depending on the field.
    private static func bool(_ value: String) -> Bool {
        switch value.lowercased() {
        case "t", "true", "1", "y": true
        default: false
        }
    }

    /// `r160` is game version 1.60; the value is the version times 100.
    private static func versionString(_ value: String) -> String {
        guard let raw = Int(value), raw > 0 else { return value }
        return "\(raw / 100).\(String(format: "%02d", raw % 100))"
    }

    /// `c0-0` is longitude-latitude, both possibly negative.
    private static func coordinates(_ value: String) -> (Int32, Int32) {
        // A leading '-' belongs to the longitude, so split on the separator, not every dash.
        var longitudeText = ""
        var latitudeText = ""
        var seenSeparator = false
        for (offset, character) in value.enumerated() {
            if character == "-", offset > 0, !seenSeparator {
                seenSeparator = true
                continue
            }
            if seenSeparator { latitudeText.append(character) } else { longitudeText.append(character) }
        }
        return (Int32(longitudeText) ?? 0, Int32(latitudeText) ?? 0)
    }

    /// ISO country code, when the server advertises one.
    var countryFlag: String? {
        guard country.count == 2 else { return nil }
        let base: UInt32 = 0x1F1E6
        var flag = ""
        for scalar in country.unicodeScalars {
            guard let value = UnicodeScalar(base + scalar.value - 65) else { return nil }
            flag.unicodeScalars.append(value)
        }
        return flag
    }
}
