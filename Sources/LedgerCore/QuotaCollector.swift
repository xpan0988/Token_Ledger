import Darwin

// The Codex request sequence and the Claude CLI /usage path are inherited from CodexBar.
import Foundation

package enum QuotaCollector {
    package struct Result: Sendable {
        package var quota: UsageSnapshot?
        package var codexProfile: CodexProfileRead?
    }

    package static func fetch(
        _ provider: ProviderInstanceID,
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment) async -> Result
    {
        let probe = Task.detached(priority: .utility) {
            switch provider {
            case .codex: (try? Self.codex(workingDirectory, environment: environment)) ?? Result()
            case .claude: Result(quota: try? Self.claude(workingDirectory, environment: environment))
            default: Result()
            }
        }
        return await withTaskCancellationHandler {
            await probe.value
        } onCancel: {
            probe.cancel()
        }
    }

    private static func codex(_ workingDirectory: URL, environment: [String: String]) throws -> Result {
        guard let command = ProviderProcess.command("codex", environment: environment) else { return Result() }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = command.executable
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.environment = command.environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { ProviderProcess.stop(process) }

        let inputFD = input.fileHandleForWriting.fileDescriptor
        let outputFD = output.fileHandleForReading.fileDescriptor
        _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
        var buffer = Data()
        var accountChanged = false
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try ProviderProcess.write(data, to: inputFD)
        }
        func response(_ id: Int, timeout: Duration) throws -> [String: Any] {
            let deadline = ContinuousClock.now + timeout
            while !Task.isCancelled, ContinuousClock.now < deadline {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                    else { continue }
                    if message["method"] as? String == "account/updated" { accountChanged = true }
                    guard message["id"] as? Int == id else { continue }
                    guard let result = message["result"] as? [String: Any] else { throw ProbeError.unavailable }
                    return result
                }
                guard let received = try ProviderProcess.read(outputFD, wait: 200) else { continue }
                guard !received.isEmpty, buffer.count <= 1_048_576 else { break }
                buffer.append(received)
            }
            throw ProbeError.unavailable
        }

        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "token-ledger", "title": "Token Ledger", "version": "1.0.0"],
        ]])
        _ = try response(1, timeout: .seconds(8))
        try send(["method": "initialized", "params": [:]])
        func request(
            _ id: Int, _ method: String, params: [String: Any]? = nil,
            timeout: Duration = .seconds(4)) -> [String: Any]?
        {
            guard !Task.isCancelled else { return nil }
            var message: [String: Any] = ["id": id, "method": method]
            message["params"] = params
            do {
                try send(message)
                return try response(id, timeout: timeout)
            } catch { return nil }
        }

        let quota = request(2, "account/rateLimits/read", params: [:], timeout: .seconds(12)).flatMap(Self.codexWindows)
        let params = ["refreshToken": false]
        guard let before = request(3, "account/read", params: params).flatMap(CodexProfileIdentity.init)
        else { return Result(quota: quota) }
        accountChanged = false
        let tokens = request(4, "account/usage/read", timeout: .seconds(8)).flatMap(CodexProfileRead.lifetimeTokens)
        guard let after = request(5, "account/read", params: params).flatMap(CodexProfileIdentity.init)
        else { return Result(quota: quota) }
        let profile = CodexProfileRead(
            cacheKey: after.cacheKey,
            tokens: before == after && !accountChanged ? tokens : nil)
        return Result(quota: quota, codexProfile: profile)
    }

    static func codexWindows(_ result: [String: Any]) -> UsageSnapshot? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> RateWindow? {
            guard let item = limits[key] as? [String: Any], let used = (item["usedPercent"] as? NSNumber)?.doubleValue,
                  used.isFinite, let minutes = item["windowDurationMins"] as? Int,
                  minutes == 300 || minutes == 10080
            else { return nil }
            let reset = (item["resetsAt"] as? Double).flatMap {
                $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
            }
            return RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset)
        }
        let primary = window("primary")
        let secondary = window("secondary")
        guard primary != nil || secondary != nil else { return nil }
        return UsageSnapshot(primary: primary, secondary: secondary)
    }

    private static func claude(_ workingDirectory: URL, environment: [String: String]) throws -> UsageSnapshot? {
        guard let command = ProviderProcess.command("claude", environment: environment) else { return nil }
        // Trust may only be granted for an owner-only empty working directory made by this probe.
        let probe = workingDirectory.appendingPathComponent("Claude Usage", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(
            at: probe,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: probe.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              try manager.contentsOfDirectory(atPath: probe.path).isEmpty
        else { return nil }

        var terminal = winsize(
            ws_row: UInt16(ClaudeCLIScreen.rows),
            ws_col: UInt16(ClaudeCLIScreen.columns),
            ws_xpixel: 0,
            ws_ypixel: 0)
        var controlFD: Int32 = -1
        var terminalFD: Int32 = -1
        guard openpty(&controlFD, &terminalFD, nil, nil, &terminal) == 0 else { return nil }
        _ = fcntl(controlFD, F_SETFL, O_NONBLOCK)
        defer { close(controlFD) }

        let process = Process()
        let tty = FileHandle(fileDescriptor: terminalFD, closeOnDealloc: true)
        process.executableURL = command.executable
        process.arguments = [
            "--allowed-tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--settings",
            #"{"remoteControlAtStartup":false,"disableAllHooks":true,"disableDeepLinkRegistration":"disable"}"#,
        ]
        var childEnvironment = command.environment.filter {
            !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE_CODE_OAUTH_")
        }
        childEnvironment["TERM"] = "xterm-256color"
        childEnvironment["DISABLE_AUTOUPDATER"] = "1"
        childEnvironment["LANG"] = "en_US.UTF-8"
        childEnvironment["LC_ALL"] = "en_US.UTF-8"
        childEnvironment["PWD"] = probe.path
        childEnvironment.removeValue(forKey: "CLAUDECODE")
        childEnvironment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        process.environment = childEnvironment
        process.currentDirectoryURL = probe
        process.standardInput = tty
        process.standardOutput = tty
        process.standardError = tty
        try process.run()
        defer { ProviderProcess.stop(process) }

        let deadline = ContinuousClock.now + .seconds(25)
        var ready = ContinuousClock.now + .seconds(2)
        var lastInput = ContinuousClock.now
        var startedUsage = false
        var acceptedPalette = false
        var best: UsageSnapshot?
        var capture = Data()
        var trustKeys = 3
        var screen = ""
        var normalized = ""
        var needsRender = false
        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])
        while !Task.isCancelled, process.isRunning, ContinuousClock.now < deadline {
            if let received = try ProviderProcess.read(controlFD, wait: 180) {
                guard !received.isEmpty, capture.count <= 512 * 1024 else { break }
                let oldEnd = capture.count
                capture.append(received)
                if capture.suffix(received.count + min(oldEnd, cursorQuery.count - 1)).range(of: cursorQuery) != nil {
                    try ProviderProcess.write(Data("\u{1b}[1;1R".utf8), to: controlFD)
                }
                needsRender = true
            }
            if needsRender, let text = String(data: capture, encoding: .utf8) {
                screen = ClaudeCLIScreen.render(text)
                normalized = screen.lowercased().filter { !$0.isWhitespace }
                needsRender = false
            }
            if normalized.contains("failedtoloadusagedata") { break }
            if normalized.contains("quicksafetycheck") || normalized.contains("doyoutrustthefilesinthisfolder") {
                if trustKeys > 0, lastInput.duration(to: .now) > .milliseconds(500),
                   let trustKey = Self.trustKey(screen)
                {
                    try ProviderProcess.write(Data(trustKey.utf8), to: controlFD)
                    trustKeys -= 1
                    lastInput = .now
                    ready = .now + .seconds(2)
                }
                continue
            }
            if !startedUsage, ContinuousClock.now >= ready, Self.claudePromptIsReady(screen) {
                try ProviderProcess.write(Data("/usage\r".utf8), to: controlFD)
                startedUsage = true
                lastInput = .now
            } else if startedUsage, let parsed = Self.claudeWindows(screen) {
                best = parsed
                if parsed.primary != nil, parsed.secondary != nil { break }
                if lastInput.duration(to: .now) > .seconds(6) { break }
            } else if startedUsage, !acceptedPalette, normalized.contains("showplan"),
                      lastInput.duration(to: .now) > .milliseconds(500)
            {
                try ProviderProcess.write(Data([0x0D]), to: controlFD)
                acceptedPalette = true
            }
        }
        return best
    }

    static func trustKey(_ screen: String) -> String? {
        let lines = screen.components(separatedBy: .newlines)
        guard let positive = lines
            .firstIndex(where: { $0.localizedCaseInsensitiveContains("Yes, I trust this folder") }),
            let active = lines.indices.first(where: { abs($0 - positive) < 3 && lines[$0].contains("❯") })
        else { return nil }
        if active == positive { return "\r" }
        return active > positive ? "\u{1b}[A" : "\u{1b}[B"
    }

    static func claudePromptIsReady(_ text: String) -> Bool {
        let tail = text.suffix(1400)
        if tail.localizedCaseInsensitiveContains("Do you trust")
            || tail.localizedCaseInsensitiveContains("Quick safety check")
            || tail.localizedCaseInsensitiveContains("Select login") { return false }
        return tail.contains("❯") || tail.localizedCaseInsensitiveContains("for shortcuts")
    }

    static func claudeWindows(_ text: String, now: Date = Date()) -> UsageSnapshot? {
        let source = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let pattern = #"(?i)(Current\s*session|Current\s*week\s*\(\s*all\s*models\s*\)"#
            + #"|Weekly\s*(?:limit|usage)\s*\(\s*all\s*models\s*\))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let found = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var session: RateWindow?
        var weekly: RateWindow?
        for (index, match) in found.enumerated() {
            guard let range = Range(match.range, in: source) else { continue }
            let next = found.indices.contains(index + 1) ? Range(found[index + 1].range, in: source)?.lowerBound : nil
            var sample = String(source[range.upperBound..<(next ?? source.endIndex)].prefix(280))
            if let scoped = sample.range(of: #"(?i)Current\s*week|Extra\s*usage"#, options: .regularExpression) {
                sample = String(sample[..<scoped.lowerBound])
            }
            let percentPattern = #"(?i)(\d{1,3}(?:\.\d+)?)\s*%\s*(used|left|remaining|available)"#
            guard let parts = Self.captures(percentPattern, sample), let value = Double(parts[0]), value <= 100 else {
                continue
            }
            let fiveHour = source[range].localizedCaseInsensitiveContains("session")
            let resetPattern = #"(?i)resets?\s+((?:[a-z]{3}\s*\d{1,2},?\s+)?\d{1,2}(?::\d{2})?"#
                + #"\s*(?:am|pm)?(?:\s*\([A-Za-z_+/:-]+\))?)"#
            let reset = Self.captures(resetPattern, sample)?.first.flatMap { Self.claudeReset($0, now: now) }
            let window = RateWindow(
                usedPercent: parts[1].lowercased() == "used" ? value : 100 - value,
                windowMinutes: fiveHour ? 300 : 10080,
                resetsAt: reset)
            if fiveHour { session = window } else { weekly = window }
        }
        guard session != nil || weekly != nil else { return nil }
        return UsageSnapshot(primary: session, secondary: weekly, updatedAt: now)
    }

    private static func claudeReset(_ text: String, now: Date) -> Date? {
        var value = text.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        if let zone = Self.captures(#"\(([^)]+)\)"#, value)?.first,
           let timeZone = TimeZone(identifier: zone)
        { calendar.timeZone = timeZone }
        value = value.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.defaultDate = calendar.startOfDay(for: now)
        for pattern in [
            "MMM d, h:mma",
            "MMM d, h:mm a",
            "MMM d h:mma",
            "MMM d, ha",
            "MMM d ha",
            "h:mma",
            "h:mm a",
            "ha",
            "h a",
            "HH:mm",
        ] {
            formatter.dateFormat = pattern
            guard let parsed = formatter.date(from: value) else { continue }
            let unit: Calendar.Component = pattern.hasPrefix("MMM") ? .year : .day
            let result = parsed >= now ? parsed : calendar.date(byAdding: unit, value: 1, to: parsed)
            return result.flatMap { $0.timeIntervalSince(now) <= 8 * 86400 ? $0 : nil }
        }
        return nil
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
