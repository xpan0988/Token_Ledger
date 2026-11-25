import Foundation

struct LegacyMigration {
    let defaults: UserDefaults
    let historyFile: URL?
    let timeZone: String?

    static func detect() -> Self? {
        let suites = ["com.steipete.codexbar", "com.steipete.codexbar.debug", "CodexBar"]
        let defaults = suites.compactMap(UserDefaults.init(suiteName:)).first { domain in
            domain.data(forKey: "tokenLedger.options.v1") != nil
                || domain.data(forKey: "tokenLedger.payments.v1") != nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        var directories = [
            xdg?.appendingPathComponent("codexbar") ?? home.appendingPathComponent(".config/codexbar"),
            home.appendingPathComponent(".codexbar"),
        ]
        if let path = ProcessInfo.processInfo.environment["CODEXBAR_CONFIG"], !path.isEmpty {
            directories.insert(
                URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    .deletingLastPathComponent(),
                at: 0)
        }
        let history = directories.map { $0.appendingPathComponent("token-ledger-history.json") }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
        guard defaults != nil || history != nil else { return nil }
        let suite = defaults ?? UserDefaults(suiteName: suites[0])!
        return Self(
            defaults: suite,
            historyFile: history,
            timeZone: suite.string(forKey: "tokenCostUsageBucketTimeZone"))
    }
}
