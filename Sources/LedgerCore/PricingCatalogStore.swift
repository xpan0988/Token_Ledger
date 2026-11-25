import CryptoKit
import Foundation

package actor PricingCatalogStore {
    typealias Download = @Sendable (URL) async throws -> Data

    private struct Check: Codable {
        var lastAttempt: Date?
        var lastDailyAttempt: Date?
    }

    private struct Manifest: Decodable {
        let sha256: String
    }

    private static let historyBase = URL(
        string: "https://raw.githubusercontent.com/wakamex/model-prices/data/v2/")!
    private static let currentURL = URL(string: "https://models.dev/api.json")!
    private static let historyName = "api-prices-history.json"
    private static let currentName = "api-prices-current.json"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    private let directory: URL
    private let download: Download
    private var check: Check
    private var queriedModels: Set<String> = []
    private var historyChecksum: String?
    private var currentChecksum: String?
    private var catalog: ModelPriceCatalog

    package init(directory: URL) {
        self.init(directory: directory, download: Self.get)
    }

    init(directory: URL, download: @escaping Download) {
        self.directory = directory
        self.download = download
        let history = try? Data(contentsOf: directory.appendingPathComponent(Self.historyName))
        let current = try? Data(contentsOf: directory.appendingPathComponent(Self.currentName))
        let catalog = ModelPriceCatalog(historicalData: history, currentData: current)
        self.catalog = catalog
        if catalog.historical != nil { self.historyChecksum = history.map(Self.sha256) }
        if catalog.current != nil { self.currentChecksum = current.map(Self.sha256) }
        let checkURL = directory.appendingPathComponent("api-prices-check.json")
        self.check = (try? Data(contentsOf: checkURL))
            .flatMap { try? JSONDecoder().decode(Check.self, from: $0) } ?? Check()
    }

    package func snapshot() -> ModelPriceCatalog { self.catalog }

    package func refresh(unknownModels: Set<String>, now: Date = Date()) async -> ModelPriceCatalog? {
        let daily = self.check.lastDailyAttempt.map { now.timeIntervalSince($0) >= 86400 } ?? true
        let novel = unknownModels.subtracting(self.queriedModels)
        let coolingDown = self.check.lastAttempt.map { now.timeIntervalSince($0) < 3600 && now >= $0 } ?? false
        guard daily || !novel.isEmpty, !coolingDown else { return nil }
        self.check.lastAttempt = now
        if daily { self.check.lastDailyAttempt = now }
        self.queriedModels.formUnion(unknownModels)
        if let bytes = try? JSONEncoder().encode(self.check) {
            try? CredentialFileWriter.writePrivate(
                bytes,
                to: self.directory.appendingPathComponent("api-prices-check.json"))
        }

        // Only the two public feeds are requested. Model IDs and ledger data stay local.
        async let historical = Self.history(download: self.download, alreadyHave: self.historyChecksum)
        async let current = try? self.download(Self.currentURL)
        let (historyData, currentData) = await (historical, current)
        let currentHash = currentData.map(Self.sha256)
        let newCurrent = currentHash == self.currentChecksum ? nil : currentData
        let candidate = ModelPriceCatalog(historicalData: historyData, currentData: newCurrent)
        if let historyData, let history = candidate.historical {
            self.catalog.historical = history
            self.historyChecksum = Self.sha256(historyData)
            try? CredentialFileWriter.writePrivate(
                historyData, to: self.directory.appendingPathComponent(Self.historyName))
        }
        if let newCurrent, let prices = candidate.current {
            self.catalog.current = prices
            self.currentChecksum = currentHash
            try? CredentialFileWriter.writePrivate(
                newCurrent, to: self.directory.appendingPathComponent(Self.currentName))
        }
        return candidate.historical != nil || candidate.current != nil ? self.catalog : nil
    }

    private static func history(download: Download, alreadyHave: String?) async -> Data? {
        guard let bytes = try? await download(historyBase.appendingPathComponent("latest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
              manifest.sha256.utf8.count == 64,
              manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              manifest.sha256 != alreadyHave,
              let snapshot = try? await download(historyBase.appendingPathComponent(manifest.sha256 + ".json")),
              sha256(snapshot) == manifest.sha256 else { return nil }
        return snapshot
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await Self.session.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 20_000_000 else { throw URLError(.badServerResponse) }
        return data
    }
}
