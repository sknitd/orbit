import Foundation

public enum PlusTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case assistant, aiUsage, sales, clipboard, teleprompter, timers, fileShelf, mirror
    case calendar, reminders, todos, weather, stocks, emoji, converter, system
    case quickNote, nowPlaying, shortcuts, launcher, workflows, fileActions
    case capture, colorPicker, hud, devices, status, network, worldClock, githubActions, focusStats

    case context, downloads, commands, snippets, translate, dictation, qr, verificationCodes, packageTracker, habits, travelStatus, sportsScores, globalSearch, plugins

    public var id: String { rawValue }
    public static let defaultOrder: [PlusTool] = [
        .assistant, .aiUsage, .sales, .clipboard, .teleprompter, .timers, .fileShelf, .mirror,
        .calendar, .reminders, .todos, .weather, .stocks, .emoji, .converter, .system,
        .quickNote, .nowPlaying, .shortcuts, .launcher, .workflows, .capture, .colorPicker,
        .hud, .devices, .status, .network, .worldClock, .githubActions, .focusStats, .context, .downloads, .commands, .snippets, .translate, .dictation, .qr, .verificationCodes, .packageTracker, .habits, .travelStatus, .sportsScores, .globalSearch, .plugins, .fileActions
    ]
    public var title: String {
        switch self {
        case .assistant: "Assistant"
        case .aiUsage: "AI Usage"
        case .sales: "Sales"
        case .clipboard: "Clipboard"
        case .teleprompter: "Teleprompter"
        case .timers: "Timers"
        case .fileShelf: "File Shelf"
        case .mirror: "Mirror"
        case .calendar: "Calendar"
        case .reminders: "Reminders"
        case .todos: "To-Dos"
        case .weather: "Weather"
        case .stocks: "Stocks"
        case .emoji: "Emoji"
        case .converter: "Converter"
        case .system: "System"
        case .quickNote: "Quick Note"
        case .nowPlaying: "Now Playing"
        case .shortcuts: "Shortcuts"
        case .launcher: "Quick Launcher"
        case .workflows: "Workflows"
        case .fileActions: "File Actions"
        case .capture: "Screenshot Shelf"
        case .colorPicker: "Color Picker"
        case .hud: "Volume & Brightness"
        case .devices: "Devices"
        case .status: "Status"
        case .network: "Network"
        case .worldClock: "World Clock"
        case .githubActions: "GitHub Actions"
        case .focusStats: "Focus Stats"
        case .context: "Context Rules"
        case .downloads: "Downloads"
        case .commands: "Commands"
        case .snippets: "Snippets"
        case .translate: "Translate"
        case .dictation: "Dictation"
        case .qr: "QR"
        case .verificationCodes: "2FA Codes"
        case .packageTracker: "Package Tracker"
        case .habits: "Habits"
        case .travelStatus: "Travel Status"
        case .sportsScores: "Sports Scores"
        case .globalSearch: "Search"
        case .plugins: "Plugins"
        }
    }
    public var symbol: String {
        switch self {
        case .assistant: "sparkles"
        case .aiUsage: "chart.bar"
        case .sales: "chart.line.uptrend.xyaxis"
        case .clipboard: "doc.on.clipboard"
        case .teleprompter: "text.alignleft"
        case .timers: "timer"
        case .fileShelf: "tray.full"
        case .mirror: "camera"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .todos: "checkmark.circle"
        case .weather: "cloud.sun"
        case .stocks: "chart.xyaxis.line"
        case .emoji: "face.smiling"
        case .converter: "arrow.left.arrow.right"
        case .system: "gauge.with.dots.needle.50percent"
        case .quickNote: "note.text"
        case .nowPlaying: "music.note"
        case .shortcuts: "command"
        case .launcher: "square.grid.2x2"
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .fileActions: "wand.and.stars"
        case .capture: "camera.viewfinder"
        case .colorPicker: "eyedropper"
        case .hud: "speaker.wave.2"
        case .devices: "headphones"
        case .status: "circle.inset.filled"
        case .network: "network"
        case .worldClock: "globe"
        case .githubActions: "play.rectangle"
        case .focusStats: "chart.bar.xaxis"
        case .context: "rectangle.3.group"
        case .downloads: "arrow.down.circle"
        case .commands: "terminal"
        case .snippets: "text.badge.plus"
        case .translate: "character.bubble"
        case .dictation: "waveform"
        case .qr: "qrcode"
        case .verificationCodes: "key"
        case .packageTracker: "shippingbox"
        case .habits: "checkmark.seal"
        case .travelStatus: "airplane"
        case .sportsScores: "sportscourt"
        case .globalSearch: "magnifyingglass"
        case .plugins: "puzzlepiece.extension"
        }
    }
    public var description: String {
        switch self {
        case .assistant: "Write and work with supported on-device language models."
        case .aiUsage: "Inspect usage reported by supported local AI tools."
        case .sales: "Read revenue from accounts you explicitly connect."
        case .clipboard: "Opt in to searchable local text, link, image, and file history."
        case .teleprompter: "Read a scrolling script beneath the camera."
        case .timers: "Run countdown and focus sessions."
        case .fileShelf: "Keep files handy, drag them out, and share through macOS."
        case .mirror: "Preview your camera before a call."
        case .calendar: "View your calendar and upcoming events."
        case .reminders: "Review and complete your Apple Reminders."
        case .todos: "Keep a local task list and star what matters."
        case .weather: "Check weather for a location you choose."
        case .stocks: "Follow chosen market symbols and inspect quoted data."
        case .emoji: "Search Unicode emoji or open the full macOS character palette."
        case .converter: "Convert length, mass, temperature, volume, and speed."
        case .system: "Inspect live information about this Mac."
        case .quickNote: "Write a local note that saves automatically."
        case .nowPlaying: "Open supported music players and their available controls."
        case .shortcuts: "Run your installed macOS Shortcuts."
        case .launcher: "Launch pinned apps, folders and favourite Shortcuts."
        case .workflows: "Run saved image-processing steps through one real drop."
        case .fileActions: "Transform files through the original authenticated drop wheel."
        case .capture: "Capture an area, window or display directly into File Shelf."
        case .colorPicker: "Pick a screen color and organize local palettes."
        case .hud: "Opt in to volume and brightness controls in the notch."
        case .devices: "Read available Mac and peripheral battery information."
        case .status: "Inspect available microphone, camera and Focus status."
        case .network: "Inspect live interface traffic and local VPN state."
        case .worldClock: "Compare chosen time zones and meeting times."
        case .githubActions: "Read your repositories and workflow runs on request."
        case .focusStats: "Review a week of completed focus sessions."
        case .context: "Preview and enable rules that change which tool the notch shows."
        case .downloads: "Observe chosen-folder partial downloads after explicit enable."
        case .commands: "Receive local command start and finish messages from your installed helper."
        case .snippets: "Keep local text and code snippets in searchable folders."
        case .translate: "Translate locally with supported on-device languages."
        case .dictation: "Hold a chosen shortcut for on-device dictation into Quick Note."
        case .qr: "Generate QR PNGs or explicitly scan a selected screen region."
        case .verificationCodes: "Opt in to volatile latest Messages codes with Full Disk Access."
        case .packageTracker: "Read tracking details from your provider on request."
        case .habits: "Check off daily habits and review streaks and seven-week history."
        case .travelStatus: "Find departure numbers in authorized Calendar events."
        case .sportsScores: "Read chosen-team scores from your connected provider."
        case .globalSearch: "Search local notes, tasks, snippets, clipboard, shelves and tools."
        case .plugins: "Explicitly enable user tools with bounded sandboxed scripts."
        }
    }
}

public enum UnitFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case length, mass, temperature, volume, speed
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var units: [ConversionUnit] { UnitConversion.units.filter { $0.family == self } }
}

public struct ConversionUnit: Identifiable, Equatable, Sendable {
    public let id: String
    public let family: UnitFamily
    public let title: String
    public let symbol: String
    public let scale: Double
    public let offset: Double
    public init(_ id: String, _ family: UnitFamily, _ title: String, _ symbol: String,
                scale: Double, offset: Double = 0) {
        self.id = id; self.family = family; self.title = title; self.symbol = symbol
        self.scale = scale; self.offset = offset
    }
}

public enum UnitConversion {
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case invalidNumber, differentFamilies, invalidUnit, belowAbsoluteZero
        public var errorDescription: String? {
            switch self {
            case .invalidNumber: "Enter a finite number within the supported numeric range."
            case .differentFamilies: "Choose units from the same measurement family."
            case .invalidUnit: "This measurement unit is invalid."
            case .belowAbsoluteZero: "Temperature cannot be below absolute zero."
            }
        }
    }
    public static let units: [ConversionUnit] = [
        .init("m", .length, "Metres", "m", scale: 1),
        .init("km", .length, "Kilometres", "km", scale: 1_000),
        .init("cm", .length, "Centimetres", "cm", scale: 0.01),
        .init("mm", .length, "Millimetres", "mm", scale: 0.001),
        .init("in", .length, "Inches", "in", scale: 0.0254),
        .init("ft", .length, "Feet", "ft", scale: 0.3048),
        .init("yd", .length, "Yards", "yd", scale: 0.9144),
        .init("mi", .length, "Miles", "mi", scale: 1_609.344),
        .init("kg", .mass, "Kilograms", "kg", scale: 1),
        .init("g", .mass, "Grams", "g", scale: 0.001),
        .init("lb", .mass, "Pounds", "lb", scale: 0.45359237),
        .init("oz", .mass, "Ounces", "oz", scale: 0.028349523125),
        .init("tonne", .mass, "Metric Tonnes", "t", scale: 1_000),
        .init("C", .temperature, "Celsius", "°C", scale: 1, offset: 273.15),
        .init("F", .temperature, "Fahrenheit", "°F", scale: 5.0 / 9.0, offset: 255.3722222222222),
        .init("K", .temperature, "Kelvin", "K", scale: 1),
        .init("L", .volume, "Litres", "L", scale: 1),
        .init("mL", .volume, "Millilitres", "mL", scale: 0.001),
        .init("m3", .volume, "Cubic Metres", "m³", scale: 1_000),
        .init("galUS", .volume, "US Gallons", "US gal", scale: 3.785411784),
        .init("galUK", .volume, "Imperial Gallons", "imp gal", scale: 4.54609),
        .init("ptUS", .volume, "US Pints", "US pt", scale: 0.473176473),
        .init("flozUS", .volume, "US Fluid Ounces", "US fl oz", scale: 0.0295735295625),
        .init("ms", .speed, "Metres per Second", "m/s", scale: 1),
        .init("kmh", .speed, "Kilometres per Hour", "km/h", scale: 1.0 / 3.6),
        .init("mph", .speed, "Miles per Hour", "mph", scale: 0.44704),
        .init("kn", .speed, "Knots", "kn", scale: 1_852.0 / 3_600),
        .init("fts", .speed, "Feet per Second", "ft/s", scale: 0.3048)
    ]
    public static func convert(_ value: Double, from source: ConversionUnit, to target: ConversionUnit) throws -> Double {
        guard value.isFinite else { throw Failure.invalidNumber }
        guard source.family == target.family else { throw Failure.differentFamilies }
        guard source.scale.isFinite, source.scale > 0, source.offset.isFinite,
              target.scale.isFinite, target.scale > 0, target.offset.isFinite else { throw Failure.invalidUnit }
        let base = value * source.scale + source.offset
        guard base.isFinite else { throw Failure.invalidNumber }
        if source.family == .temperature, base < -0.000000001 { throw Failure.belowAbsoluteZero }
        let result = ((source.family == .temperature ? max(0, base) : base) - target.offset) / target.scale
        guard result.isFinite else { throw Failure.invalidNumber }
        return result
    }
}

public struct ToDoItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var completed: Bool
    public var starred: Bool
    public let createdAt: Date
    public init(id: UUID = UUID(), title: String, completed: Bool = false, starred: Bool = false,
                createdAt: Date = Date()) {
        self.id = id; self.title = title; self.completed = completed
        self.starred = starred; self.createdAt = createdAt
    }
}

public enum ShelfRetention: String, CaseIterable, Codable, Sendable, Identifiable {
    case hour, day, week, forever
    public var id: String { rawValue }
    public var title: String {
        switch self { case .hour: "1 hour"; case .day: "24 hours"; case .week: "7 days"; case .forever: "Forever" }
    }
    public var duration: TimeInterval? {
        switch self { case .hour: 3_600; case .day: 86_400; case .week: 604_800; case .forever: nil }
    }
}

public struct FileShelfItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let originalURL: URL
    public let managedURL: URL?
    public let bookmark: Data?
    public let addedAt: Date
    public init(id: UUID = UUID(), originalURL: URL, managedURL: URL? = nil,
                bookmark: Data? = nil, addedAt: Date = Date()) {
        self.id = id; self.originalURL = originalURL; self.managedURL = managedURL
        self.bookmark = bookmark; self.addedAt = addedAt
    }
    public func expired(at date: Date, retention: ShelfRetention) -> Bool {
        guard let duration = retention.duration else { return false }
        return date.timeIntervalSince(addedAt) >= duration
    }
}

public struct FileShelfState: Codable, Equatable, Sendable {
    public var items: [FileShelfItem]
    public var autoSave: Bool
    public var retention: ShelfRetention
    public init(items: [FileShelfItem] = [], autoSave: Bool = false, retention: ShelfRetention = .week) {
        self.items = items; self.autoSave = autoSave; self.retention = retention
    }
    public func expiredItems(at date: Date) -> [FileShelfItem] {
        items.filter { $0.expired(at: date, retention: retention) }
    }
}
