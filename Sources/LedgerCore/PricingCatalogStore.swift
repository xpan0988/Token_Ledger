import CryptoKit
import Foundation

package actor PricingCatalogStore {
    typealias Download = @Sendable (URL) async throws -> Data

    private struct Snapshot: Codable {
        var catalog = ModelPriceCatalog()
        var lastAttempt: Date?
        var historyHash: String?
    }

    private struct Manifest: Decodable {
        let sha256: String
    }

    private static let history = URL(string: "https://raw.githubusercontent.com/wakamex/model-prices/data/v2/")!
    private static let current = URL(string: "https://models.dev/api.json")!
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
    private var cached: Snapshot?

    package init(directory: URL) {
        self.init(directory: directory) { try await Self.get($0) }
    }

    init(directory: URL, download: @escaping Download) {
        self.directory = directory
        self.download = download
    }

    package func snapshot() -> ModelPriceCatalog { self.load().catalog }

    package func refresh(now: Date = Date()) async -> ModelPriceCatalog? {
        var snapshot = self.load()
        if let last = snapshot.lastAttempt, (0..<86400).contains(now.timeIntervalSince(last)) { return nil }
        snapshot.lastAttempt = now
        self.persist(snapshot)
        let update: ModelPriceCatalog?
        if let bytes = try? await self.download(Self.history.appendingPathComponent("latest.json")),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
           manifest.sha256.utf8.count == 64,
           manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        {
            guard manifest.sha256 != snapshot.historyHash else { return nil }
            if let data = try? await self.download(Self.history.appendingPathComponent(manifest.sha256 + ".json")),
               Self.sha256(data) == manifest.sha256, let catalog = ModelPriceCatalog(history: data, now: now)
            {
                snapshot.historyHash = manifest.sha256
                update = catalog
            } else {
                update = await self.current()
            }
        } else {
            update = snapshot.historyHash == nil ? await self.current() : nil
        }
        guard let update else { return nil }
        snapshot.catalog.merge(update)
        self.persist(snapshot)
        return snapshot.catalog
    }

    private var file: URL {
        self.directory.appendingPathComponent("api-prices.json")
    }

    private func load() -> Snapshot {
        if let cached = self.cached { return cached }
        if let data = try? Data(contentsOf: self.file), let snapshot = try? JSONDecoder().decode(
            Snapshot.self,
            from: data)
        {
            self.cached = snapshot
            return snapshot
        }
        var snapshot = Snapshot()
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("api-prices-history.json")),
           let history = ModelPriceCatalog(history: data)
        {
            snapshot.catalog = history
            snapshot.historyHash = Self.sha256(data)
        } else if let data = try? Data(contentsOf: self.directory.appendingPathComponent("api-prices-current.json")),
                  let current = ModelPriceCatalog(current: data)
        {
            snapshot.catalog = current
        }
        if self.persist(snapshot) {
            for name in ["api-prices-history.json", "api-prices-current.json", "api-prices-check.json"] {
                try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(name))
            }
        }
        return snapshot
    }

    @discardableResult
    private func persist(_ snapshot: Snapshot) -> Bool {
        self.cached = snapshot
        do {
            try CredentialFileWriter.writePrivate(JSONEncoder().encode(snapshot), to: self.file)
            return true
        } catch { return false }
    }

    private func current() async -> ModelPriceCatalog? {
        guard let data = try? await self.download(Self.current) else { return nil }
        return ModelPriceCatalog(current: data)
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
