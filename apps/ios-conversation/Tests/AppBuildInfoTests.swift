import XCTest
@testable import cat

/// Settings › 关于 version row: parsing the build stamp, Asia/Shanghai display and graceful fallbacks.
final class AppBuildInfoTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let stamped: [String: Any] = [
        "CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "712",
        "CatpawBuildDate": "2026-10-17T23:30:00Z", "CatpawGitSHA": "1a2b3c4d",
        "CatpawGitDirty": false, "CatpawBuildConfiguration": "DeviceTrial",
    ]

    func testStampedInfoFormatsVersionAndShanghaiReleaseTime() {
        let info = AppBuildInfo(info: stamped)
        XCTAssertTrue(info.isStamped)
        XCTAssertEqual(info.versionLabel, "1.1.0 (build 712)")
        XCTAssertEqual(info.buildDateLabel(timeZone: shanghai), "2026-10-18 07:30", "UTC 23:30 is 07:30 next day in Shanghai")
        XCTAssertEqual(info.buildDateLabel(timeZone: TimeZone(identifier: "UTC")!), "2026-10-17 23:30")
        XCTAssertEqual(info.commitLabel, "1a2b3c4d")
        XCTAssertEqual(info.diagnosticText, "cat 1.1.0 (712) · 1a2b3c4d · 2026-10-17T23:30:00Z · DeviceTrial")
    }

    func testFractionalSecondsAndDirtyMarker() {
        var raw = stamped
        raw["CatpawBuildDate"] = "2026-10-17T23:30:59.250Z"
        raw["CatpawGitDirty"] = true
        let info = AppBuildInfo(info: raw)
        XCTAssertEqual(info.buildDateLabel(timeZone: shanghai), "2026-10-18 07:30")
        XCTAssertEqual(info.commitLabel, "1a2b3c4d+dirty")
        XCTAssertTrue(info.diagnosticText.contains("1a2b3c4d+dirty"))
    }

    func testMissingStampFallsBackWithoutInventingValues() {
        let info = AppBuildInfo(info: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "1"])
        XCTAssertFalse(info.isStamped)
        XCTAssertNil(info.buildDateLabel(timeZone: shanghai))
        XCTAssertNil(info.commitLabel)
        XCTAssertEqual(info.versionLabel, "1.1.0 (build 1)")
        XCTAssertEqual(info.diagnosticText, "cat 1.1.0 (1)")
    }

    func testEmptyUnprocessedAndGarbageValuesAreTreatedAsMissing() {
        let info = AppBuildInfo(info: [
            "CFBundleShortVersionString": "  ", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
            "CatpawBuildDate": "yesterday", "CatpawGitSHA": "", "CatpawGitDirty": "yes",
        ])
        XCTAssertNil(info.version)
        XCTAssertNil(info.build)
        XCTAssertNil(info.buildDate)
        XCTAssertNil(info.gitSHA)
        XCTAssertFalse(info.gitDirty)
        XCTAssertEqual(info.versionLabel, "— (build —)")
        XCTAssertEqual(AppBuildInfo(info: nil).diagnosticText, "cat ? (?)")
    }

    func testDateLabelIsLocaleIndependent() {
        let info = AppBuildInfo(info: stamped)
        // Fixed POSIX pattern: same digits whatever the device calendar/locale, so bug reports compare cleanly.
        XCTAssertEqual(info.buildDateLabel(timeZone: shanghai)?.count, 16)
        XCTAssertNotNil(info.buildDateLabel(timeZone: shanghai)?.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression))
    }

    func testRunningAppCarriesTheVersionFromVersionXcconfig() {
        let info = AppBuildInfo.current
        XCTAssertNotNil(info.version.flatMap { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) }, "SemVer from Version.xcconfig")
        XCTAssertNotNil(info.build.flatMap { Int($0) }, "Build number is a positive integer (commit count or fallback)")
    }

    func testSettingsStringsExistInBothLanguages() {
        for key in ["版本 {0} (build {1})", "发布于 {0}", "构建于 {0} · 含未提交修改", "开发构建 · 未记录发布时间", "复制版本信息", "提交 {0}"] {
            let zh = AppLanguage.chinese.ui(key, arguments: ["1.1.0", "712"])
            let en = AppLanguage.english.ui(key, arguments: ["1.1.0", "712"])
            XCTAssertFalse(zh.isEmpty, key)
            XCTAssertNotEqual(zh, en, key)
        }
        XCTAssertEqual(AppLanguage.chinese.ui("版本 {0} (build {1})", arguments: ["1.1.0", "712"]), "版本 1.1.0 (build 712)")
        XCTAssertEqual(AppLanguage.english.ui("发布于 {0}", arguments: ["2026-10-18 07:30"]), "Released 2026-10-18 07:30")
    }
}
