import Foundation

/// Decode manufacture date from serial.
/// Pre-2021 11/12-char serials encode year/week in positions 4–5.
/// From 2021, randomized (often 10-char) serials can't be dated locally — say so, don't invent.
enum SerialDecoder {

    struct Manufacture {
        let year: Int
        let week: Int
    }

    private static let yearAlphabet = Array("CDFGHJKLMNPQRSTVWXYZ")
    private static let weekAlphabet = Array("123456789CDFGHJKLMNPQRTVWXY")

    static func manufacture(from serial: String) -> Manufacture? {
        let s = serial.uppercased()
        guard s.count == 11 || s.count == 12 else { return nil }
        let chars = Array(s)
        let yearChar = chars[3]
        let weekChar = chars[4]
        guard let yi = yearAlphabet.firstIndex(of: yearChar),
              let wi = weekAlphabet.firstIndex(of: weekChar) else { return nil }
        let year = 2010 + yi / 2
        let half = yi % 2
        let week = (half == 1 ? 26 : 0) + (wi + 1)
        return Manufacture(year: year, week: min(week, 53))
    }

    /// Plant / region from classic serial prefix (3-char preferred, then 2-char).
    /// Only meaningful for pre-randomized serials.
    static func productionOrigin(for serial: String) -> String? {
        let s = serial.uppercased()
        guard s.count >= 2 else { return nil }
        let p3 = String(s.prefix(3))
        if p3 == "C02" { return L10n.t("serial.origin.c02") }
        switch String(s.prefix(2)) {
        case "C0", "C3", "C7": return L10n.t("serial.origin.foxconn_sz")
        case "FK", "F1", "F2": return L10n.t("serial.origin.foxconn_zz")
        case "DN": return L10n.t("serial.origin.foxconn_cd")
        case "W8": return L10n.t("serial.origin.shanghai")
        case "CK": return L10n.t("serial.origin.cork")
        case "VM": return L10n.t("serial.origin.foxconn_cz")
        case "FC", "XA", "XB": return L10n.t("serial.origin.usa")
        case "RN": return L10n.t("serial.origin.mexico")
        default: return nil
        }
    }

    /// Plain-language date result; randomized serials get an explicit note, not empty.
    /// Classic serials may append plant/region when the prefix is known.
    static func productionDescription(serial: String) -> String {
        guard !serial.isEmpty else { return L10n.t("serial.prod.unknown") }
        if let m = manufacture(from: serial) {
            if let origin = productionOrigin(for: serial) {
                return L10n.t("serial.prod.week_origin", m.year, m.week, origin)
            }
            return L10n.t("serial.prod.week", m.year, m.week)
        }
        return L10n.t("serial.prod.randomized")
    }
}
