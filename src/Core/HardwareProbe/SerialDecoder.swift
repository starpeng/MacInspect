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

    /// Plain-language date result; randomized serials get an explicit note, not empty.
    static func productionDescription(serial: String) -> String {
        guard !serial.isEmpty else { return L10n.t("serial.prod.unknown") }
        if let m = manufacture(from: serial) {
            return L10n.t("serial.prod.week", m.year, m.week)
        }
        return L10n.t("serial.prod.randomized")
    }
}
