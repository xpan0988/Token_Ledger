import Darwin
import Foundation

enum ProviderProcess {
    static func command(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (executable: URL, environment: [String: String])?
    {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = [
            "\(home)/.local/bin", "\(home)/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        let path = ((environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallback)
            .filter { $0.hasPrefix("/") && seen.insert($0).inserted }
        guard let executable = path.lazy.map({ URL(fileURLWithPath: $0).appendingPathComponent(name) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return nil }
        // CLI launchers such as the npm Codex script resolve their interpreter through PATH.
        var child = environment
        child["PATH"] = path.joined(separator: ":")
        return (executable, child)
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now + .milliseconds(250)
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    static func read(_ descriptor: Int32, wait: Int32) throws -> Data? {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&poller, 1, wait)
        if ready == 0 || (ready < 0 && errno == EINTR) { return nil }
        guard ready > 0 else { throw ProbeError.unavailable }
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return nil }
        if count < 0, errno == EIO { return Data() }
        guard count >= 0 else { throw ProbeError.unavailable }
        return Data(buffer.prefix(count))
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        guard data.withUnsafeBytes({
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }) == data.count else { throw ProbeError.unavailable }
    }
}

enum ProbeError: Error {
    case unavailable
}
