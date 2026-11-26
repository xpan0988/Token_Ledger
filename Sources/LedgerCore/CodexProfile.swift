import CoreFoundation
import Foundation

struct CodexProfileIdentity: Equatable {
    private let user: String
    private let workspace: String?

    init?(_ response: [String: Any]) {
        guard let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt",
              let user = response["userId"] as? String, !user.isEmpty else { return nil }
        self.user = LedgerIdentity.hash(user)
        if let routing = response["workspaceRouting"] as? [String: Any],
           let workspace = routing["chatgptAccountId"] as? String, !workspace.isEmpty,
           let origin = routing["backendOrigin"] as? String, !origin.isEmpty
        {
            self.workspace = LedgerIdentity.hash(workspace) + LedgerIdentity.hash(origin)
        } else {
            self.workspace = nil
        }
    }

    var cacheKey: String? {
        self.workspace.map { LedgerIdentity.hash(self.user + $0) }
    }
}

package struct CodexProfileRead: Sendable {
    let cacheKey: String?
    let tokens: Int64?

    static func lifetimeTokens(_ result: [String: Any]) -> Int64? {
        guard let summary = result["summary"] as? [String: Any],
              let number = summary["lifetimeTokens"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let tokens = Int64(number.stringValue), tokens >= 0 else { return nil }
        return tokens
    }
}

package struct CodexProfileValue: Equatable, Sendable {
    package let tokens: Int64
    package let cached: Bool
}

/// A cached value is usable only after app-server confirms the same user and workspace.
package struct CodexProfileCache {
    private struct Entry: Codable, Equatable {
        let key: String
        let tokens: Int64
    }

    private let file: URL
    private var entry: Entry?
    private var persisted = true

    package init(file: URL) {
        self.file = file
        self.entry = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
    }

    package mutating func resolve(_ read: CodexProfileRead?) -> CodexProfileValue? {
        guard let read else { return nil }
        if let tokens = read.tokens, tokens >= 0 {
            if let key = read.cacheKey {
                let entry = Entry(key: key, tokens: tokens)
                if entry != self.entry || !self.persisted {
                    self.persisted = self.save(entry)
                    self.entry = entry
                }
            }
            return CodexProfileValue(tokens: tokens, cached: false)
        }
        guard let entry = self.entry, entry.key == read.cacheKey, entry.tokens >= 0 else { return nil }
        return CodexProfileValue(tokens: entry.tokens, cached: true)
    }

    private func save(_ entry: Entry) -> Bool {
        do {
            try CredentialFileWriter.writePrivate(JSONEncoder().encode(entry), to: self.file)
            return true
        } catch { return false }
    }
}
