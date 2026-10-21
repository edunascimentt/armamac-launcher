import Foundation

/// Arma 3's field of view, as stored in a `.Arma3Profile`.
///
/// The profile does not hold degrees. It holds two tangents:
///
/// ```
/// fovTop  = tan(verticalFOV   / 2)
/// fovLeft = tan(horizontalFOV / 2)
/// ```
///
/// and the two are tied together by the display aspect ratio, `fovLeft / fovTop`. The stock
/// values are `fovTop = 0.75`, `fovLeft = 1.333333`, i.e. 73.7° vertical on a 16:9 display.
/// Writing one without the other is what produces the stretched picture people complain
/// about, so this type always derives the pair together.
struct FieldOfView: Equatable, Sendable {
    var fovTop: Double
    var fovLeft: Double

    /// The values Arma ships with, for a 16:9 display.
    static let arma3Default = FieldOfView(fovTop: 0.75, fovLeft: 1.333333)

    /// Horizontal FOV in degrees is what every FOV calculator and community guide quotes.
    var horizontalDegrees: Double {
        2 * atan(fovLeft) * 180 / .pi
    }

    var verticalDegrees: Double {
        2 * atan(fovTop) * 180 / .pi
    }

    /// `fovLeft / fovTop` — the aspect ratio the values were computed for.
    var aspectRatio: Double {
        fovTop > 0 ? fovLeft / fovTop : 16.0 / 9.0
    }

    /// Builds the pair from a horizontal FOV and the display's aspect ratio.
    init(horizontalDegrees: Double, aspectRatio: Double) {
        let clampedFOV = min(max(horizontalDegrees, Self.minimumHorizontal), Self.maximumHorizontal)
        let aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        fovLeft = tan(clampedFOV / 2 * .pi / 180)
        fovTop = fovLeft / aspect
    }

    /// Builds the pair from a vertical FOV and the display's aspect ratio.
    init(verticalDegrees: Double, aspectRatio: Double) {
        let aspect = aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
        let vertical = min(max(verticalDegrees, 20), 130)
        fovTop = tan(vertical / 2 * .pi / 180)
        fovLeft = fovTop * aspect
    }

    init(fovTop: Double, fovLeft: Double) {
        self.fovTop = fovTop
        self.fovLeft = fovLeft
    }

    /// Arma clamps the camera itself; going far outside this range just warps the image.
    static let minimumHorizontal: Double = 50
    static let maximumHorizontal: Double = 140

    /// Common display shapes, plus whatever the profile was already set to.
    static let commonAspectRatios: [(name: String, value: Double)] = [
        ("16:9", 16.0 / 9.0),
        ("16:10", 16.0 / 10.0),
        ("21:9", 64.0 / 27.0),
        ("32:9", 32.0 / 9.0),
        ("4:3", 4.0 / 3.0),
        ("3:2", 3.0 / 2.0),
    ]

    /// Horizontal FOV values Arma players actually ask for, by name.
    ///
    /// The stock value is unusually wide already; the lower ones trade peripheral vision
    /// for apparent zoom, which helps at range.
    static let presets: [(name: String, horizontal: Double, detail: String)] = [
        ("Default", arma3Default.horizontalDegrees, "What Arma ships with"),
        ("Zoomed", 90, "Narrower — targets look closer"),
        ("Wide", 120, "More peripheral vision"),
    ]

    /// Formats a value the way Arma writes it into the profile.
    static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    var fovTopText: String { Self.format(fovTop) }
    var fovLeftText: String { Self.format(fovLeft) }

    /// Name of the closest standard aspect ratio, for display.
    var aspectRatioName: String {
        let ratio = aspectRatio
        let match = Self.commonAspectRatios.min {
            abs($0.value - ratio) < abs($1.value - ratio)
        }
        guard let match, abs(match.value - ratio) < 0.02 else {
            return String(format: "%.2f:1", ratio)
        }
        return match.name
    }
}
