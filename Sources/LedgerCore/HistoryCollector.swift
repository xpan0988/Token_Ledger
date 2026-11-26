import CryptoKit
import Foundation

struct TranscriptCursor: Codable {
    var fileID: UInt64
    var offset: UInt64 = 0
    var modified: Date?
    var size: UInt64?
    var complete = false
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

    private struct Scan {
        let provider: ProviderInstanceID
        let store: UsageStore
        let migrating: Bool
        var remaining: Int
        let deadline: ContinuousClock.Instant
    }

    private let file: URL
    private let legacyFile: URL?
    private let legacyZone: String?
    private let locations: UsageLocations
    private var store: UsageStore?
    private var state: LedgerState?
    private var backup: URL?
    private var preview: [ProviderInstanceID: UsageSummary] = [:]
    private var previewed: Set<ProviderInstanceID> = []
    private var inventory: [ProviderInstanceID: [URL]] = [:]
    private var nextFile: [ProviderInstanceID: Int] = [:]
    private var enabled: Set<ProviderInstanceID> = []
    private var prices = ModelPriceCatalog()
    private var lastPartial = false

    package init(file: URL, locations: UsageLocations, legacyFile: URL? = nil, legacyZone: String? = nil) {
        self.file = file
        self.locations = locations
        self.legacyFile = legacyFile
        self.legacyZone = legacyZone
    }

    @discardableResult
    package func updatePricing(_ prices: ModelPriceCatalog) -> TokenLedgerTotals? {
        self.prices = prices
        return self.state.map { self.totals($0, enabled: self.enabled, partial: self.lastPartial) }
    }

    package func collect(_ enabled: Set<ProviderInstanceID>) -> Result {
        var pending = false
        var failed = false
        do {
            let store = try self.open()
            if self.inventory.isEmpty || self.enabled != enabled {
                self.enabled = enabled
                self.inventory = [:]
                self.nextFile = [:]
                for provider in enabled.sorted() {
                    self.inventory[provider] = self.files(provider)
                }
            }
            var nextFile = self.nextFile
            let deadline = ContinuousClock.now + .seconds(2)
            var remaining = 64 * 1024 * 1024
            let state = try store.transaction { store in
                var state = try store.load(LedgerState.self, .summary, "totals") ?? .init()
                var changed = false
                var completed = Set<ProviderInstanceID>()
                for provider in enabled.sorted() {
                    let files = self.inventory[provider] ?? []
                    var index = nextFile[provider] ?? 0
                    let migrating = self.backup != nil && !state.reconciled.contains(provider)
                    var scan = Scan(
                        provider: provider,
                        store: store,
                        migrating: migrating,
                        remaining: remaining,
                        deadline: deadline)
                    while files.indices.contains(index), scan.remaining > 0, ContinuousClock.now < deadline {
                        let outcome = try autoreleasepool {
                            try self.read(file: files[index], state: &state, scan: &scan)
                        }
                        changed = changed || outcome.changed
                        if !outcome.ended { break }
                        index += 1
                    }
                    remaining = scan.remaining
                    if migrating, index == files.count { completed.insert(provider) }
                    nextFile[provider] = index
                    pending = pending || index < files.count
                }
                if let backup = self.backup, !completed.isEmpty {
                    try autoreleasepool {
                        let original = try self.priorLedger(PriorLedger.self, backup)
                        for provider in completed {
                            try original.reconcile(provider, into: &state, store: store)
                        }
                    }
                    if state.reconciled.isSuperset(of: ProviderInstanceID.supported) {
                        try store.clear(.migration)
                    }
                    changed = true
                }
                if changed { try store.save(state, .summary, "totals") }
                return state
            }
            self.state = state
            self.nextFile = nextFile
            if !pending {
                self.inventory = [:]
                self.nextFile = [:]
            }
            let disabled = Set(ProviderInstanceID.supported).subtracting(enabled).subtracting(state.reconciled)
            if let backup = self.backup, !disabled.isSubset(of: self.previewed) {
                self
                    .preview = try autoreleasepool {
                        try self.priorLedger(PriorLedger.self, backup).preview(for: disabled)
                    }
                self.previewed = disabled
            }
        } catch {
            failed = true
        }
        self.lastPartial = pending || failed
        let totals = self.totals(self.state ?? LedgerState(), enabled: enabled, partial: self.lastPartial)
        return Result(totals: totals, pending: pending && !failed, persistenceFailed: failed)
    }

    private func totals(_ state: LedgerState, enabled: Set<ProviderInstanceID>, partial: Bool) -> TokenLedgerTotals {
        state.totals(enabled: enabled, pending: partial, prices: self.prices, preview: self.preview.filter {
            !enabled.contains($0.key) && !state.reconciled.contains($0.key)
        })
    }

    package func delete(through cutoff: Date = Date()) -> Bool {
        do {
            let store = try self.open()
            self.state = try store.transaction { store in
                let previous = try store.load(LedgerState.self, .summary, "totals")
                let state = LedgerState(
                    timeZone: previous?.timeZone ?? TimeZone.current.identifier,
                    deletedThrough: cutoff,
                    reconciled: Set(ProviderInstanceID.supported))
                for table in [UsageStore.Table.codex, .claude, .migration, .recovered] {
                    try store.clear(table)
                }
                try store.save(state, .summary, "totals")
                return state
            }
            let backup = self.backupFile
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            self.backup = nil
            self.preview = [:]
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
        file: URL, state: inout LedgerState, scan: inout Scan) throws -> (ended: Bool, changed: Bool)
    {
        let key = LedgerIdentity.hash(file.path)
        let old = try scan.store.load(TranscriptCursor.self, .cursor, key)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { return (true, false) }
            let modified = attributes[.modificationDate] as? Date
            let sameFile = old?.fileID == inode && old?.modified == modified && old?.size == size
            if sameFile, old?.complete == true { return (true, false) }
            var cursor = TranscriptCursor(fileID: inode)
            let ended: Bool
            if file.pathExtension == "zst" {
                if sameFile, let old { cursor = old }
                ended = try self.readArchive(
                    file, cursor: &cursor, state: &state, scan: &scan)
            } else {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                if let old, old.fileID == inode, old.offset <= size,
                   try self.anchor(handle, at: old.offset) == old.anchor
                {
                    cursor = old
                }
                try handle.seek(toOffset: cursor.offset)
                ended = try self.readLines(
                    handle, cursor: &cursor, state: &state, scan: &scan, acceptLast: false)
                cursor.anchor = try self.anchor(handle, at: cursor.offset)
            }
            cursor.modified = modified
            cursor.size = size
            cursor.complete = ended
            try scan.store.save(cursor, .cursor, key)
            if cursor.parser.partial { state.partialProviders.insert(scan.provider) }
            return (ended, true)
        } catch let error as UsageStore.Failure {
            throw error
        } catch {
            let changed = state.partialProviders.insert(scan.provider).inserted
            return (true, changed)
        }
    }

    private func readArchive(
        _ file: URL, cursor: inout TranscriptCursor, state: inout LedgerState, scan: inout Scan) throws -> Bool
    {
        guard let command = ProviderProcess.command("zstd") else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = command.executable
        process.arguments = ["-dc", "--", file.path]
        process.environment = command.environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { ProviderProcess.stop(process) }
        let handle = pipe.fileHandleForReading
        var skip = cursor.offset
        while skip > 0 {
            guard let bytes = try handle.read(upToCount: Int(min(skip, 128 * 1024))), !bytes.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            skip -= UInt64(bytes.count)
        }
        let ended = try self.readLines(
            handle, cursor: &cursor, state: &state, scan: &scan, acceptLast: true)
        if ended {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        return ended
    }

    private func anchor(_ handle: FileHandle, at offset: UInt64) throws -> Data? {
        guard offset > 0 else { return nil }
        let length = min(offset, 128)
        try handle.seek(toOffset: offset - length)
        guard let bytes = try handle.read(upToCount: Int(length)) else { return nil }
        return Data(SHA256.hash(data: bytes))
    }

    private func readLines(
        _ handle: FileHandle, cursor: inout TranscriptCursor, state: inout LedgerState,
        scan: inout Scan, acceptLast: Bool) throws -> Bool
    {
        let maximumLine = 2 * 1024 * 1024
        let deadline = acceptLast ? max(scan.deadline, .now + .milliseconds(500)) : scan.deadline
        var buffered = Data()
        while scan.remaining > 0, ContinuousClock.now < deadline {
            guard let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty else {
                if acceptLast, !buffered.isEmpty, !cursor.discardingLine,
                   let observation = cursor.parser.consume(buffered, provider: scan.provider)
                {
                    try state.record(observation, store: scan.store, migrating: scan.migrating)
                }
                return true
            }
            scan.remaining -= chunk.count
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 0x0A) {
                let count = chunk.distance(from: start, to: end)
                let length = buffered.count + count
                if !cursor.discardingLine, length <= maximumLine {
                    buffered.append(chunk[start..<end])
                    if let observation = cursor.parser.consume(buffered, provider: scan.provider) {
                        try state.record(observation, store: scan.store, migrating: scan.migrating)
                    }
                } else if scan.provider == .claude || buffered.range(of: Data("token_usage_record".utf8)) != nil {
                    cursor.parser.partial = true
                }
                cursor.offset += UInt64(length + 1)
                cursor.discardingLine = false
                buffered.removeAll(keepingCapacity: true)
                start = chunk.index(after: end)
            }
            let tail = chunk[start...]
            if cursor.discardingLine || buffered.count + tail.count > maximumLine {
                if scan.provider == .claude || buffered.range(of: Data("token_usage_record".utf8)) != nil {
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

    private func open() throws -> UsageStore {
        if let store = self.store { return store }
        let manager = FileManager.default
        let prior = self.file.deletingLastPathComponent().appendingPathComponent("history.json")
        let backup = self.backupFile
        if manager.fileExists(atPath: prior.path), !manager.fileExists(atPath: backup.path) {
            // Rename on the same volume preserves the original bytes before creating a new format.
            try manager.moveItem(at: prior, to: backup)
            CredentialFileWriter.repairPermissions(at: backup)
        }
        let store = try UsageStore(file: self.file)
        let exists = manager.fileExists(atPath: backup.path)
        if exists { self.backup = backup }
        self.state = try store.transaction { store in
            if let state = try store.load(LedgerState.self, .summary, "totals") { return state }
            var state = LedgerState(timeZone: self.legacyZone ?? TimeZone.current.identifier)
            if exists {
                let original = try self.priorLedger(PriorLedger.Metadata.self, backup)
                state.timeZone = original.timeZone
                state.deletedThrough = original.deletedThrough
                state.observedProviders = original.observedProviders
                state.legacyDays = original.legacyDays
                state.legacyUndated = original.legacyUndated
            } else if let legacyFile, let data = try? Data(contentsOf: legacyFile),
                      let legacy = try? JSONDecoder().decode(LegacyHistory.self, from: data)
            {
                legacy.importSelected(into: &state)
            }
            try store.save(state, .summary, "totals")
            return state
        }
        self.store = store
        return store
    }

    private var backupFile: URL {
        self.file.deletingLastPathComponent().appendingPathComponent("history-v1.backup.json")
    }

    private func priorLedger<Value: Decodable>(_ type: Value.Type, _ file: URL) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: file, options: .mappedIfSafe))
    }
}
