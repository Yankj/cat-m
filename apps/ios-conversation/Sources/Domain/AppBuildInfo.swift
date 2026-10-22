import Foundation

/// Identity of the installed package, shown in Settings › 关于 and copied into bug reports.
///
/// `CFBundleShortVersionString` comes from Configuration/Version.xcconfig. `CFBundleVersion` (the git commit count),
/// `CatpawBuildDate` (UTC ISO 8601), `CatpawGitSHA`, `CatpawGitDirty` and `CatpawBuildConfiguration` are written into the
/// packaged Info.plist by the "Stamp Build Info" build phase (Scripts/app-version.py stamp). Every field is optional so
/// previews, unit-test hosts and shallow CI builds without a stamp still render a sensible row.
public struct AppBuildInfo: Equatable, Sendable {
    public enum Key {
        public static let version = "CFBundleShortVersionString"
        public static let build = "CFBundleVersion"
        public static let date = "CatpawBuildDate"
        public static let sha = "CatpawGitSHA"
        public static let dirty = "CatpawGitDirty"
        public static let configuration = "CatpawBuildConfiguration"
    }

    public let version: String?
    public let build: String?
    public let buildDate: Date?
    public let gitSHA: String?
    public let gitDirty: Bool
    public let configuration: String?

    public init(version: String?, build: String?, buildDate: Date?, gitSHA: String?, gitDirty: Bool = false, configuration: String? = nil) {
        self.version = Self.clean(version)
        self.build = Self.clean(build)
        self.buildDate = buildDate
        self.gitSHA = Self.clean(gitSHA)
        self.gitDirty = gitDirty
        self.configuration = Self.clean(configuration)
    }

    public init(info: [String: Any]?) {
        let info = info ?? [:]
        // An unexpanded "$(CURRENT_PROJECT_VERSION)" means the plist was never processed; treat it as missing.
        func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.hasPrefix("$(") ? nil : $0 } }
        self.init(version: text(Key.version), build: text(Key.build), buildDate: text(Key.date).flatMap(Self.parseDate),
                  gitSHA: text(Key.sha), gitDirty: (info[Key.dirty] as? Bool) ?? false, configuration: text(Key.configuration))
    }

    public static var current: AppBuildInfo { AppBuildInfo(info: Bundle.main.infoDictionary) }

    /// Accepts `2026-10-17T23:30:00Z` (what the stamp writes) and the fractional-seconds variant.
    public static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// True when the build phase stamped this package (date present). Unstamped = local preview or shallow CI build.
    public var isStamped: Bool { buildDate != nil }

    /// `1.1.0 (build 712)`; `—` parts when the plist lacks a value.
    public var versionLabel: String { "\(version ?? "—") (build \(build ?? "—"))" }

    /// `2026-10-18 07:30` in `timeZone` (the device zone in the UI; Asia/Shanghai for this user). Fixed POSIX pattern so
    /// the value is identical in Chinese and English and in bug reports.
    public func buildDateLabel(timeZone: TimeZone = .current) -> String? {
        guard let buildDate else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: buildDate)
    }

    /// Short commit with a `+dirty` marker for a build made from uncommitted changes.
    public var commitLabel: String? { gitSHA.map { $0 + (gitDirty ? "+dirty" : "") } }

    /// Single-line, language-neutral identity for bug reports and the copy action:
    /// `cat 1.1.0 (712) · 1a2b3c4d · 2026-10-17T23:30:00Z · DeviceTrial`.
    public var diagnosticText: String {
        var parts = ["cat \(version ?? "?") (\(build ?? "?"))"]
        if let commitLabel { parts.append(commitLabel) }
        if let buildDate {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            parts.append(iso.string(from: buildDate))
        }
        if let configuration { parts.append(configuration) }
        return parts.joined(separator: " · ")
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
