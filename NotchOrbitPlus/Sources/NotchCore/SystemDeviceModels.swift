import Foundation

public struct SystemDeviceSnapshot: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let connection: String
    public let connected: Bool?
    public let batteryPercent: Double?
    public let detail: String?
    public init(id: String, name: String, connection: String, connected: Bool? = nil, batteryPercent: Double? = nil, detail: String? = nil) {
        self.id = id; self.name = name; self.connection = connection; self.connected = connected
        self.batteryPercent = batteryPercent.flatMap(Self.validBatteryPercent)
        self.detail = detail
    }
    public static func validBatteryPercent(_ value: Double) -> Double? {
        value.isFinite && (0...100).contains(value) ? value : nil
    }
    public static func batteryPercent(current: Double, maximum: Double) -> Double? {
        guard current.isFinite, maximum.isFinite, maximum > 0, current >= 0, current <= maximum else { return nil }
        return validBatteryPercent(100 * current / maximum)
    }
}
public enum SystemFocusAuthorization: String, Codable, Sendable, CaseIterable {
    case notConnected, notDetermined, restricted, denied, authorized, unavailable
}
public struct SystemFocusSnapshot: Sendable, Equatable {
    public let authorization: SystemFocusAuthorization
    public let isFocused: Bool?
    public init(authorization: SystemFocusAuthorization, isFocused: Bool? = nil) {
        self.authorization = authorization
        self.isFocused = authorization == .authorized ? isFocused : nil
    }
    public var statusDescription: String {
        switch authorization {
        case .notConnected: "Connect Focus to request permission to read the status shared by macOS."
        case .notDetermined: "Focus authorization has not been decided."
        case .restricted: "macOS restricts Focus status access for this app."
        case .denied: "Focus status access is denied. Change Focus sharing in System Settings to grant access."
        case .unavailable: "The public Focus status service is unavailable on this system."
        case .authorized:
            if let isFocused { isFocused ? "macOS reports that Focus is active." : "macOS reports that Focus is not active." }
            else { "Focus status is not shared, unavailable, or monitoring is paused." }
        }
    }
}
public struct SystemStatusSnapshot: Sendable, Equatable {
    public let inputDeviceName: String?
    public let inputDeviceIsRunning: Bool?
    public let cameraInUseByAnotherApplication: Bool?
    public let cameraStatus: String
    public let focus: SystemFocusSnapshot
    public var focusIsActive: Bool? { focus.isFocused }
    public let date: Date
    public init(inputDeviceName: String?, inputDeviceIsRunning: Bool?, cameraInUseByAnotherApplication: Bool?, cameraStatus: String, date: Date = Date(), focus: SystemFocusSnapshot = .init(authorization: .notConnected)) {
        self.inputDeviceName = inputDeviceName; self.inputDeviceIsRunning = inputDeviceIsRunning
        self.cameraInUseByAnotherApplication = cameraInUseByAnotherApplication; self.cameraStatus = cameraStatus; self.date = date; self.focus = focus
    }
}
public struct OrbitNetworkInterface: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let isUp: Bool
    public let isRunning: Bool
    public let isLoopback: Bool
    public let addresses: [String]
    public let bytes: OrbitNetworkBytes?
    public init(name: String, isUp: Bool, isRunning: Bool, isLoopback: Bool = false, addresses: [String] = [], bytes: OrbitNetworkBytes? = nil) {
        self.name = name; self.isUp = isUp; self.isRunning = isRunning; self.isLoopback = isLoopback
        self.addresses = addresses; self.bytes = bytes
    }
    public var isActive: Bool { isUp && isRunning && !isLoopback }
    public var isTunnel: Bool { ["utun", "tun", "tap", "ppp", "ipsec"].contains { name.hasPrefix($0) } }
}
