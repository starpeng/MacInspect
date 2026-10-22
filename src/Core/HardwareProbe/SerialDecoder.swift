import Foundation

/// 序列号生产日期解码。
/// 2021 年前 Apple 使用 11/12 位序列号，其中第 4、5 位编码了生产年份与周次，可本地解码。
/// 2021 年起 Apple 改用随机化序列号（通常 10 位），**无法**本地推算日期——诚实告知，不臆造。
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

    /// 给出人话的生产日期结论。随机化序列号返回明确说明而非空。
    static func productionDescription(serial: String) -> String {
        guard !serial.isEmpty else { return L10n.t("serial.prod.unknown") }
        if let m = manufacture(from: serial) {
            return L10n.t("serial.prod.week", m.year, m.week)
        }
        return L10n.t("serial.prod.randomized")
    }
}
