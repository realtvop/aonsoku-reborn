import AonsokuKit
import Foundation

enum Formatters {
    /// Track time: "3:07", or "1:02:03" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }

    /// A list's total length, such as "1 hr, 5 min".
    static func totalDuration(_ seconds: Int, locale: Locale) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600
            ? [.hours, .minutes]
            : [.minutes]
        let style = Duration.UnitsFormatStyle(allowedUnits: units, width: .abbreviated)
            .locale(locale)
        return Duration.seconds(max(seconds, 60)).formatted(style)
    }

    static func bytes(_ bytes: Int64, locale: Locale) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    /// Cache sizes and quotas in binary units, so a 1 GiB quota reads
    /// "1 GB" as on the web.
    static func cacheSize(_ bytes: Int64, locale: Locale) -> String {
        bytes.formatted(.byteCount(style: .memory).locale(locale))
    }

    static func relative(_ date: Date, locale: Locale) -> String {
        date.formatted(.relative(presentation: .named).locale(locale))
    }

    static func date(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale))
    }

    static func dateTime(_ date: Date, locale: Locale) -> String {
        date.formatted(
            .dateTime.year().month(.abbreviated).day().hour().minute().locale(locale)
        )
    }

    static func number(_ value: Int, locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }

    /// A release date as precise as the server knows it: "March 3, 2021",
    /// "March 2021" or "2021".
    static func releaseDate(_ date: ItemDate, locale: Locale) -> String? {
        guard let year = date.year, year > 0 else { return nil }
        guard let month = date.month, (1 ... 12).contains(month) else { return String(year) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let day = date.day.flatMap { (1 ... 31).contains($0) ? $0 : nil }
        let components = DateComponents(year: year, month: month, day: day ?? 1)
        guard let value = calendar.date(from: components) else { return String(year) }
        var style = day == nil
            ? Date.FormatStyle.dateTime.year().month(.wide)
            : Date.FormatStyle.dateTime.year().month(.wide).day()
        style.timeZone = calendar.timeZone
        style.locale = locale
        return value.formatted(style)
    }

    /// "FLAC · 24-bit/96 kHz" style quality line for a song.
    static func quality(of song: Song) -> String? {
        var parts: [String] = []
        if let suffix = song.suffix, !suffix.isEmpty {
            parts.append(suffix.uppercased())
        }
        if let depth = song.bitDepth, depth > 0, let rate = song.samplingRate, rate > 0 {
            parts.append("\(depth)-bit/\(kilohertz(rate)) kHz")
        } else if let bitRate = song.bitRate, bitRate > 0 {
            parts.append("\(bitRate) kbps")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func kilohertz(_ hertz: Int) -> String {
        let value = Double(hertz) / 1000
        return value.rounded() == value
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    /// Decibels with a sign, such as "+3.2 dB".
    static func decibels(_ value: Double) -> String {
        String(format: "%+.1f dB", value)
    }
}
