import Foundation
import Testing
@testable import LedgerCore

struct CodexProfileTests {
    @Test
    func `profile replaces only the Codex component of the displayed total`() {
        var totals = TokenLedgerTotals()
        totals.tokens = [.codex: 500, .claude: 400]
        totals.apiCosts = [.init(currency: "USD", value: 70)]
        #expect(totals.displayTokens(codexLifetime: 750) == 1150)
        #expect(totals.displayTokens(codexLifetime: 0) == 400)
        #expect(totals.displayTokens(codexLifetime: nil) == 900)
        #expect(totals.tokens == [.codex: 500, .claude: 400])
        #expect(totals.apiCosts == [.init(currency: "USD", value: 70)])
    }

    @Test
    func `cache reuse requires the same user and workspace and accepts server revisions`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("profile.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try #require(self.identity(user: "first", workspace: "personal")?.cacheKey)
        let anotherUser = try #require(self.identity(user: "second", workspace: "personal")?.cacheKey)
        let anotherSpace = try #require(self.identity(user: "first", workspace: "work")?.cacheKey)
        var cache = CodexProfileCache(file: file)
        #expect(cache.resolve(.init(cacheKey: original, tokens: 750)) == .init(tokens: 750, cached: false))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("personal"))

        var reloaded = CodexProfileCache(file: file)
        #expect(reloaded.resolve(.init(cacheKey: original, tokens: nil)) == .init(tokens: 750, cached: true))
        #expect(reloaded.resolve(.init(cacheKey: anotherUser, tokens: nil)) == nil)
        #expect(reloaded.resolve(.init(cacheKey: anotherSpace, tokens: nil)) == nil)
        #expect(reloaded.resolve(nil) == nil)
        #expect(self.identity(user: "first", workspace: nil)?.cacheKey == nil)
        #expect(reloaded.resolve(.init(cacheKey: nil, tokens: 990)) == .init(tokens: 990, cached: false))
        #expect(reloaded.resolve(.init(cacheKey: nil, tokens: nil)) == nil)
        #expect(reloaded.resolve(.init(cacheKey: original, tokens: 700)) == .init(tokens: 700, cached: false))
        var revised = CodexProfileCache(file: file)
        #expect(revised.resolve(.init(cacheKey: original, tokens: nil)) == .init(tokens: 700, cached: true))
    }

    @Test
    func `profile decoder accepts an integer lifetime count and rejects unavailable values`() {
        for invalid: Any in [true, -1, 3.5, "100", NSNull()] {
            #expect(CodexProfileRead.lifetimeTokens(["summary": ["lifetimeTokens": invalid]]) == nil)
        }
        #expect(CodexProfileRead.lifetimeTokens(["dailyUsageBuckets": [["tokens": 123]]]) == nil)
        #expect(CodexProfileRead.lifetimeTokens(["summary": ["lifetimeTokens": 7_410_000_001]]) == 7_410_000_001)
    }

    @Test
    func `codex reuses its quota process and rejects a profile under a changing account`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let script = #"""
        #!/bin/sh
        reads=0
        while IFS= read -r request; do
          request=$(printf '%s' "$request" | /usr/bin/sed 's|\\/|/|g')
          case "$request" in
            *'"initialize"'*) echo '{"id":1,"result":{}}' ;;
            *'"account/rateLimits/read"'*)
              echo '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}'
              ;;
            *'"account/read"'*)
              reads=$((reads + 1))
              if [ "$reads" = 1 ]; then request_id=3; workspace=personal; else request_id=5; workspace="$SECOND"; fi
              route='"chatgptAccountId":"'"$workspace"'","backendOrigin":"https://chatgpt.com"'
              printf '{"id":%s,"result":{"account":{"type":"chatgpt"},"userId":"first",%s}}\n' \
                "$request_id" '"workspaceRouting":{'"$route"'}'
              ;;
            *'"account/usage/read"'*)
              case "$request" in *'"params"'*) exit 1 ;; esac
              if [ "$AVAILABLE" = yes ]; then
                echo '{"id":4,"result":{"summary":{"lifetimeTokens":750}}}'
              else
                echo '{"id":4,"error":{"code":-32601}}'
              fi
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let fresh = await QuotaCollector.fetch(
            .codex, workingDirectory: directory, environment: [
                "PATH": directory.path,
                "SECOND": "personal",
                "AVAILABLE": "yes",
            ])
        #expect(fresh.quota?.primary?.usedPercent == 20)
        #expect(fresh.codexProfile?.tokens == 750)
        let unsupported = await QuotaCollector.fetch(
            .codex, workingDirectory: directory, environment: ["PATH": directory.path, "SECOND": "personal"])
        #expect(unsupported.quota?.primary?.usedPercent == 20)
        #expect(unsupported.codexProfile?.cacheKey == fresh.codexProfile?.cacheKey)
        #expect(unsupported.codexProfile?.tokens == nil)
        let switched = await QuotaCollector.fetch(
            .codex, workingDirectory: directory, environment: [
                "PATH": directory.path,
                "SECOND": "work",
                "AVAILABLE": "yes",
            ])
        #expect(switched.codexProfile?.cacheKey != fresh.codexProfile?.cacheKey)
        #expect(switched.codexProfile?.tokens == nil)
    }

    private func identity(user: String, workspace: String?) -> CodexProfileIdentity? {
        var response: [String: Any] = ["userId": user, "account": ["type": "chatgpt"]]
        if let workspace {
            response["workspaceRouting"] = ["chatgptAccountId": workspace, "backendOrigin": "https://chatgpt.com"]
        }
        return CodexProfileIdentity(response)
    }
}
