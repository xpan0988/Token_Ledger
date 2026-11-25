import CryptoKit
import Foundation

struct TranscriptCursor: Codable {
    var fileID: UInt64
    var offset: UInt64 = 0
    var modified: Date?
    var anchor: Data?
    var discardingLine = false
    var parser = TranscriptState()
}

package struct UsageLocations: Sendable {
    package let codex: URL
    package let claude: URL

    package init(codex: URL, claude: URL) {
        self.codex = codex
        self.claude = claude
    }

    package static func local(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func directory(_ variable: String, _ fallback: String) -> URL {
            guard let value = environment[variable],
                  !value.isEmpty else { return home.appendingPathComponent(fallback) }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL
        }
        return Self(codex: directory("CODEX_HOME", ".codex"), claude: directory("CLAUDE_CONFIG_DIR", ".claude"))
    }

    func roots(for provider: ProviderInstanceID) -> [URL] {
        if provider == .codex {
            return ["sessions", "archived_sessions"].map { self.codex.appendingPathComponent($0) }
        }
        return [self.claude.appendingPathComponent("projects")]
    }
}

package actor HistoryCollector {
    package struct Result: Sendable {
        package let totals: TokenLedgerTotals
        package let pending: Bool
        package let persistenceFailed: Bool
    }

    private let file: URL
    private let legacyFile: URL?
    private let legacyZone: String?
    private let locations: UsageLocations
    private var state: LedgerState?
    private var unreadable = false
    private var dirty = false
    private var inventory: [ProviderInstanceID: [URL]] = [:]
    private var nextFile: [ProviderInstanceID: Int] = [:]
    private var enabled: Set<ProviderInstanceID> = []
    private var prices = ModelPriceCatalog()

    package init(file: URL, locations: UsageLocations, legacyFile: URL? = nil, legacyZone: String? = nil) {
        self.file = file
        self.locations = locations
        self.legacyFile = legacyFile
        self.legacyZone = legacyZone
    }

    package func updatePricing(_ prices: ModelPriceCatalog) {
        self.prices = prices
    }

    package func collect(_ enabled: Set<ProviderInstanceID>) -> Result {
        var state = self.state ?? self.load()
        if self.inventory.isEmpty || self.enabled != enabled {
            self.enabled = enabled
            self.inventory = [:]
            self.nextFile = [:]
            for provider in enabled.sorted() {
                self.inventory[provider] = self.files(provider)
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        var remaining = 64 * 1024 * 1024
        var pending = false
        for provider in enabled.sorted() {
            let files = self.inventory[provider] ?? []
            var index = self.nextFile[provider] ?? 0
            while files.indices.contains(index), remaining > 0, ContinuousClock.now < deadline {
                let outcome = self.read(
                    file: files[index],
                    provider: provider,
                    state: &state,
                    budget: &remaining,
                    deadline: deadline)
                if !outcome { break }
                index += 1
            }
            self.nextFile[provider] = index
            pending = pending || index < files.count
        }
        if !pending {
            self.inventory = [:]
            self.nextFile = [:]
        }
        self.state = state
        let failed = !self.saveIfNeeded(state)
        let missing = !Set(state.events.values.map(\.provider)).union(state.observedProviders).isSuperset(of: enabled)
        return Result(
            totals: state.totals(stale: enabled.isEmpty, partial: pending || missing, prices: self.prices),
            pending: pending,
            persistenceFailed: failed)
    }

    package func delete(through cutoff: Date = Date()) -> Bool {
        var state = self.state ?? self.load()
        state.delete(through: cutoff)
        // Explicit deletion also replaces a damaged file. Commit before publishing the reset.
        do {
            try CredentialFileWriter.writePrivate(JSONEncoder().encode(state), to: self.file)
            self.state = state
            self.unreadable = false
            self.dirty = false
            return true
        } catch { return false }
    }

    private func files(_ provider: ProviderInstanceID) -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .isSymbolicLinkKey]
        return self.locations.roots(for: provider).flatMap { root -> [URL] in
            guard let files = manager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return [] }
            return files.compactMap { entry -> (URL, Date)? in
                guard let url = entry as? URL,
                      url
                          .pathExtension == "jsonl" ||
                          (provider == .codex && url.lastPathComponent.hasSuffix(".jsonl.zst")),
                          let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true, values.isSymbolicLink != true
                else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }.map(\.0)
        }
    }

    private func read(
        file: URL,
        provider: ProviderInstanceID,
        state: inout LedgerState,
        budget: inout Int,
        deadline: ContinuousClock.Instant) -> Bool
    {
        let key = LedgerIdentity.hash(file.path)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { return true }
            let modified = attributes[.modificationDate] as? Date
            let old = state.cursors[key]
            if old?.fileID == inode, old?.modified == modified { return true }
            var cursor = TranscriptCursor(fileID: inode)
            if file.pathExtension == "zst" {
                return self.readArchive(
                    file,
                    provider: provider,
                    key: key,
                    cursor: .init(fileID: inode),
                    modified: modified,
                    state: &state)
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            if let old, old.fileID == inode, old.offset <= size,
               try self.anchor(handle, at: old.offset) == old.anchor
            {
                cursor = old
            }
            try handle.seek(toOffset: cursor.offset)
            let ended = try self.readLines(
                handle,
                provider: provider,
                cursor: &cursor,
                state: &state,
                budget: &budget,
                deadline: deadline,
                acceptLast: false)
            if ended { cursor.modified = modified }
            cursor.anchor = try self.anchor(handle, at: cursor.offset)
            state.cursors[key] = cursor
            self.dirty = true
            if cursor.parser.partial { state.partialProviders.insert(provider) }
            return ended
        } catch {
            state.partialProviders.insert(provider)
            self.dirty = true
            return true
        }
    }

    private func readArchive(
        _ file: URL, provider: ProviderInstanceID, key: String, cursor initial: TranscriptCursor,
        modified: Date?, state: inout LedgerState) -> Bool
    {
        guard let command = ProviderProcess.command("zstd") else {
            state.partialProviders.insert(provider)
            self.dirty = true
            return true
        }
        var cursor = initial
        do {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = command.executable
            process.arguments = ["-dc", "--", file.path]
            process.environment = command.environment
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { ProviderProcess.stop(process) }
            var limit = 160 * 1024 * 1024
            let ended = try self.readLines(
                pipe.fileHandleForReading,
                provider: provider,
                cursor: &cursor,
                state: &state,
                budget: &limit,
                deadline: .now + .seconds(4),
                acceptLast: true)
            if !ended || cursor.parser.partial || (process.isRunning == false && process.terminationStatus != 0) {
                state.partialProviders.insert(provider)
            }
            cursor.modified = modified
            state.cursors[key] = cursor
        } catch {
            state.partialProviders.insert(provider)
        }
        self.dirty = true
        return true
    }

    private func anchor(_ handle: FileHandle, at offset: UInt64) throws -> Data? {
        guard offset > 0 else { return nil }
        let length = min(offset, 128)
        try handle.seek(toOffset: offset - length)
        guard let bytes = try handle.read(upToCount: Int(length)) else { return nil }
        return Data(SHA256.hash(data: bytes))
    }

    private func readLines(
        _ handle: FileHandle, provider: ProviderInstanceID, cursor: inout TranscriptCursor,
        state: inout LedgerState, budget: inout Int, deadline: ContinuousClock.Instant, acceptLast: Bool) throws -> Bool
    {
        let maximumLine = 2 * 1024 * 1024
        var buffered = Data()
        while budget > 0, ContinuousClock.now < deadline {
            guard let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty else {
                if acceptLast, !buffered.isEmpty, !cursor.discardingLine,
                   let observation = cursor.parser.consume(buffered, provider: provider)
                {
                    state.record(observation, provider: provider)
                }
                return true
            }
            budget -= chunk.count
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 0x0A) {
                let count = chunk.distance(from: start, to: end)
                let length = buffered.count + count
                if !cursor.discardingLine, length <= maximumLine {
                    buffered.append(chunk[start..<end])
                    if let observation = cursor.parser.consume(buffered, provider: provider) {
                        state.record(observation, provider: provider)
                    }
                } else if provider == .claude || buffered.range(of: Data("token_usage_record".utf8)) != nil {
                    cursor.parser.partial = true
                }
                cursor.offset += UInt64(length + 1)
                cursor.discardingLine = false
                buffered.removeAll(keepingCapacity: true)
                start = chunk.index(after: end)
            }
            let tail = chunk[start...]
            if cursor.discardingLine || buffered.count + tail.count > maximumLine {
                if provider == .claude || buffered.range(of: Data("token_usage_record".utf8)) != nil {
                    cursor.parser.partial = true
                }
                cursor.offset += UInt64(buffered.count + tail.count)
                buffered.removeAll(keepingCapacity: true)
                cursor.discardingLine = true
            } else {
                buffered.append(tail)
            }
        }
        return false
    }

    private func load() -> LedgerState {
        var state = LedgerState(timeZone: self.legacyZone ?? TimeZone.current.identifier)
        if FileManager.default.fileExists(atPath: self.file.path) {
            do {
                var restored = try JSONDecoder().decode(LedgerState.self, from: Data(contentsOf: self.file))
                if restored.pricingInputsVersion == nil {
                    // Revisit accessible originals once. Keep unmatched pre-migration token records.
                    restored.cursors.removeAll()
                    restored.pricingInputsVersion = 1
                    self.dirty = true
                }
                return restored
            } catch { self.unreadable = true }
        } else if let legacyFile, let data = try? Data(contentsOf: legacyFile),
                  let legacy = try? JSONDecoder().decode(LegacyHistory.self, from: data)
        {
            legacy.importSelected(into: &state)
            self.dirty = true
        }
        return state
    }

    private func saveIfNeeded(_ state: LedgerState) -> Bool {
        if self.unreadable { return false }
        if self.dirty {
            do {
                try CredentialFileWriter.writePrivate(JSONEncoder().encode(state), to: self.file)
                self.dirty = false
            } catch { return false }
        }
        return true
    }
}
