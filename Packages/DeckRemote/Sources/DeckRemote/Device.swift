import Foundation
import DeckKit

public enum SessionMode: String, Codable, Sendable { case game, desktop, unknown }

public struct Volume: Codable, Equatable, Sendable {
    public var name: String
    public var mountPoint: String
    public var total: Int64
    public var free: Int64
}

public struct DeviceStatus: Codable, Equatable, Sendable {
    public var osVersion: String?
    public var buildID: String?
    public var model: String?
    public var batteryPercent: Int?
    public var batteryState: String?
    public var internalStorage: Volume?
    public var sdCard: Volume?
    public var temperatures: [String: Double] = [:]
    public var mode: SessionMode = .unknown

    public init() {}
}

/// Comandos de leitura e os parsers da saída deles. Cada comando tem fixture em `Tests/.../Fixtures`.
public enum DeviceProbe {
    /// O `systemctl --user` e o `steamosctl` precisam achar o barramento mesmo numa sessão SSH crua.
    public static let userBus = "export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; "

    public static let osRelease = "cat /etc/os-release"
    public static let board = "cat /sys/class/dmi/id/board_name 2>/dev/null"
    // `BAT*`: Valve usa BAT1 no LCD e no OLED, mas o glob não depende disso.
    public static let battery = "cat /sys/class/power_supply/BAT*/capacity /sys/class/power_supply/BAT*/status 2>/dev/null"
    public static let disks = "df -B1 --output=source,target,size,avail /home; df -B1 --output=source,target,size,avail 2>/dev/null | grep mmcblk"
    public static let temperatures = "for d in /sys/class/hwmon/hwmon*; do printf '%s %s\\n' \"$(cat $d/name)\" \"$(cat $d/temp1_input 2>/dev/null)\"; done"
    public static let session = userBus + "if systemctl --user is-active --quiet gamescope-session.target; then echo game; elif pgrep -x plasmashell >/dev/null; then echo desktop; else echo unknown; fi"

    public static func parseOSRelease(_ text: String, into status: inout DeviceStatus) {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if parts[0] == "VERSION_ID" { status.osVersion = value }
            if parts[0] == "BUILD_ID" { status.buildID = value }
        }
    }

    public static func modelName(board: String) -> String? {
        switch board.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Jupiter": "Steam Deck LCD"
        case "Galileo": "Steam Deck OLED"
        case "Fremont": "Fremont"
        case "": nil
        case let other: other
        }
    }

    public static func parseBattery(_ text: String, into status: inout DeviceStatus) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        status.batteryPercent = lines.lazy.compactMap { Int($0) }.first
        status.batteryState = lines.first { Int($0) == nil }
    }

    public static func parseDisks(_ text: String, into status: inout DeviceStatus) {
        let volumes: [(source: String, volume: Volume)] = text.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4, let size = Int64(f[f.count - 2]), let free = Int64(f[f.count - 1]) else { return nil }
            let mount = f[1..<(f.count - 2)].joined(separator: " ")
            return (f[0], Volume(name: URL(fileURLWithPath: mount).lastPathComponent, mountPoint: mount, total: size, free: free))
        }
        status.internalStorage = volumes.first.map { var v = $0.volume; v.name = "Internal"; return v }
        status.sdCard = volumes.dropFirst().first { $0.source.contains("mmcblk") }?.volume
    }

    public static func parseTemperatures(_ text: String, into status: inout DeviceStatus) {
        let labels = ["k10temp": "CPU", "amdgpu": "GPU", "nvme": "SSD", "steamdeck_hwmon": "Board", "jupiter": "Board"]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 2, let label = labels[f[0]], let milli = Double(f[1]) else { continue }
            status.temperatures[label] = milli / 1000
        }
    }

    public static func read(_ runner: any CommandRunner) async throws -> DeviceStatus {
        async let os = runner.run(osRelease)
        async let boardResult = runner.run(board)
        async let batteryResult = runner.run(battery)
        async let disksResult = runner.run(disks)
        async let temps = runner.run(temperatures)
        async let sessionResult = runner.run(session)
        var status = DeviceStatus()
        parseOSRelease(try await os.stdout, into: &status)
        status.model = modelName(board: try await boardResult.stdout)
        parseBattery(try await batteryResult.stdout, into: &status)
        parseDisks(try await disksResult.stdout, into: &status)
        parseTemperatures(try await temps.stdout, into: &status)
        status.mode = SessionMode(rawValue: try await sessionResult.trimmed) ?? .unknown
        return status
    }
}

/// Arquivos no Deck. Binários viajam em base64 e toda escrita é tmp + rename no mesmo diretório.
public struct RemoteFiles: Sendable {
    public let runner: any CommandRunner

    public init(runner: any CommandRunner) { self.runner = runner }

    public func home() async throws -> String {
        try await runner.check("printf %s \"$HOME\"").stdout
    }

    public func read(_ path: String) async throws -> Data? {
        let r = try await runner.run("base64 -w0 \(Shell.quote(path)) 2>/dev/null")
        guard r.ok else { return nil }
        return Data(base64Encoded: r.trimmed)
    }

    public func write(_ data: Data, to path: String) async throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = path + ".quietdeck-tmp"
        try await runner.check(RemoteCommand("mkdir -p \(Shell.quote(dir)) && cat > \(Shell.quote(tmp)) && mv -f \(Shell.quote(tmp)) \(Shell.quote(path))", stdin: data, timeout: 60))
    }

    public func exists(_ path: String) async throws -> Bool {
        try await runner.run("test -e \(Shell.quote(path))").ok
    }
}
