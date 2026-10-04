import Foundation

public enum SyncFailure: LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

/// Causal counters decide whether an edit observed another edit. Wall-clock skew never discards an edit.
public struct SyncVector: Codable, Equatable, Sendable {
    public var counters: [String: UInt64]
    public init(_ counters: [String: UInt64] = [:]) { self.counters = counters }
    public mutating func observe(_ other: Self) {
        for (key, value) in other.counters { counters[key] = max(counters[key, default: 0], value) }
    }
    public func covers(_ other: Self) -> Bool { other.counters.allSatisfy { counters[$0.key, default: 0] >= $0.value } }
    public func dominates(_ other: Self) -> Bool { covers(other) && self != other }
    public mutating func advance(_ device: UUID) throws {
        let key = device.uuidString, old = counters[key, default: 0]
        guard old < 1_000_000_000_000 else { throw SyncFailure.invalid("This device’s sync counter is out of range.") }
        counters[key] = old + 1
        try validate()
    }
    public func validate() throws {
        guard counters.count <= 32, counters.allSatisfy({ key, value in
            UUID(uuidString: key)?.uuidString == key && value > 0 && value <= 1_000_000_000_000
        }) else { throw SyncFailure.invalid("Invalid or excessive sync device counters.") }
    }
}

public struct SyncRevision<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let deviceID: UUID
    public let writtenAt: Date
    public var clock: SyncVector
    public let value: Value
    public init(id: UUID = UUID(), deviceID: UUID, writtenAt: Date, clock: SyncVector, value: Value) {
        self.id = id; self.deviceID = deviceID; self.writtenAt = writtenAt; self.clock = clock; self.value = value
    }
}

/// A multi-value register retains concurrent variants. Explicit resolution creates an edit that observes all variants.
public struct SyncRegister<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var revisions: [SyncRevision<Value>]
    public init(_ revisions: [SyncRevision<Value>] = []) { self.revisions = revisions }
    public func preferred(on device: UUID) -> Value? {
        revisions.first(where: { $0.deviceID == device })?.value ?? revisions.first?.value
    }
    public var hasConflict: Bool { revisions.count > 1 }
    public func merged(with other: Self) throws -> Self {
        var identities: [UUID: SyncRevision<Value>] = [:]
        for revision in revisions + other.revisions {
            if var old = identities[revision.id] {
                guard old.value == revision.value, old.deviceID == revision.deviceID, old.writtenAt == revision.writtenAt else {
                    throw SyncFailure.invalid("A sync revision identity was reused with different content.")
                }
                old.clock.observe(revision.clock); identities[revision.id] = old
            } else { identities[revision.id] = revision }
        }
        let candidates = Array(identities.values)
        var survivors = candidates.filter { candidate in
            !candidates.contains { $0.id != candidate.id && $0.clock.dominates(candidate.clock) }
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        // Identical concurrent values can safely share their combined causal history.
        var result: [SyncRevision<Value>] = []
        for revision in survivors {
            if let index = result.firstIndex(where: { $0.value == revision.value }) {
                result[index].clock.observe(revision.clock)
            } else { result.append(revision) }
        }
        survivors = result.filter { candidate in !result.contains { $0.id != candidate.id && $0.clock.dominates(candidate.clock) } }
        guard survivors.count <= 8 else { throw SyncFailure.invalid("More than eight concurrent variants need manual consolidation before syncing.") }
        return Self(survivors)
    }
    public mutating func set(_ value: Value, device: UUID, at date: Date, clock: SyncVector) {
        revisions = [SyncRevision(deviceID: device, writtenAt: date, clock: clock, value: value)]
    }
    public func validate(context: SyncVector) throws {
        guard revisions.count <= 8, Set(revisions.map(\.id)).count == revisions.count else { throw SyncFailure.invalid("Invalid sync revision list.") }
        for revision in revisions {
            try revision.clock.validate()
            guard revision.clock.counters[revision.deviceID.uuidString, default: 0] > 0, context.covers(revision.clock),
                  revision.writtenAt.timeIntervalSince1970.isFinite,
                  (-62_135_596_800...253_402_300_799).contains(revision.writtenAt.timeIntervalSince1970) else {
                throw SyncFailure.invalid("Invalid sync revision metadata.")
            }
        }
    }
}

public struct SyncSharedSettings: Codable, Equatable, Sendable {
    public var toolOrder: [String]
    public var hiddenToolIDs: [String]
    public var openMode: String
    public var hoverDelay: Double
    public var appearance: CoreAppearancePreferences?
    public var livePriority: LiveNotchPriorityConfiguration?
    public var worldZoneIDs: [String]?
    public init(toolOrder: [String] = PlusTool.defaultOrder.map(\.id), hiddenToolIDs: [String] = [], openMode: String = "hoverAndClick", hoverDelay: Double = 0.2,
                appearance: CoreAppearancePreferences? = nil, livePriority: LiveNotchPriorityConfiguration? = nil, worldZoneIDs: [String]? = nil) {
        self.toolOrder = toolOrder; self.hiddenToolIDs = hiddenToolIDs; self.openMode = openMode; self.hoverDelay = hoverDelay
        self.appearance = appearance; self.livePriority = livePriority; self.worldZoneIDs = worldZoneIDs
    }
    private enum CodingKeys: String, CodingKey { case toolOrder, hiddenToolIDs, openMode, hoverDelay, appearance, livePriority, worldZoneIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(toolOrder: try values.decode([String].self, forKey: .toolOrder), hiddenToolIDs: try values.decode([String].self, forKey: .hiddenToolIDs),
                  openMode: try values.decode(String.self, forKey: .openMode), hoverDelay: try values.decode(Double.self, forKey: .hoverDelay),
                  appearance: try values.decodeIfPresent(CoreAppearancePreferences.self, forKey: .appearance),
                  livePriority: try values.decodeIfPresent(LiveNotchPriorityConfiguration.self, forKey: .livePriority),
                  worldZoneIDs: try values.decodeIfPresent([String].self, forKey: .worldZoneIDs))
    }
    public func validate() throws {
        let known = Set(PlusTool.allCases.map(\.id))
        guard toolOrder.count <= known.count, Set(toolOrder).count == toolOrder.count, Set(toolOrder).isSubset(of: known),
              hiddenToolIDs.count <= known.count, Set(hiddenToolIDs).count == hiddenToolIDs.count, Set(hiddenToolIDs).isSubset(of: known),
              ["hoverAndClick", "clickOnly"].contains(openMode), hoverDelay.isFinite, (0...1.5).contains(hoverDelay) else {
            throw SyncFailure.invalid("Unsupported shared settings. Display geometry, shortcuts, permissions and accounts are never synced.")
        }
        try livePriority?.validate()
        if let worldZoneIDs {
            guard worldZoneIDs.count <= 12, Set(worldZoneIDs).count == worldZoneIDs.count,
                  worldZoneIDs.allSatisfy({ $0.count <= 120 && TimeZone(identifier: $0) != nil }) else {
                throw SyncFailure.invalid("Shared World Clock settings need at most twelve unique valid time zones.")
            }
        }
    }
}

public struct SyncTaskRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public var title: SyncRegister<String>
    public var completed: SyncRegister<Bool>
    public var starred: SyncRegister<Bool>
    public var deleted: SyncRegister<Bool>
    public var isDeleted: Bool { deleted.revisions.contains { $0.value } }
    public var hasConflict: Bool { title.hasConflict || completed.hasConflict || starred.hasConflict || deleted.hasConflict }
    public func item(on device: UUID) -> ToDoItem? {
        guard !isDeleted, let title = title.preferred(on: device), let completed = completed.preferred(on: device), let starred = starred.preferred(on: device) else { return nil }
        return ToDoItem(id: id, title: title, completed: completed, starred: starred, createdAt: createdAt)
    }
    public func merged(with other: Self) throws -> Self {
        guard id == other.id, createdAt == other.createdAt else { throw SyncFailure.invalid("A task identity was reused with a different creation date.") }
        return Self(id: id, createdAt: createdAt, title: try title.merged(with: other.title), completed: try completed.merged(with: other.completed),
            starred: try starred.merged(with: other.starred), deleted: try deleted.merged(with: other.deleted))
    }
}

public struct SyncSnapshot: Codable, Equatable, Sendable {
    public static let maximumBytes = 8 * 1024 * 1024
    public var schemaVersion = 3
    public let deviceID: UUID
    public var generatedAt: Date
    public var context: SyncVector
    public var note: SyncRegister<String>
    public var settings: SyncRegister<SyncSharedSettings>
    public var tasks: [SyncTaskRecord]
    public var launcherPins: SyncRegister<[SyncLauncherPin]>
    public var workflows: SyncRegister<[WorkflowPreset]>
    public var palettes: SyncRegister<CoreColorPaletteLibrary>
    public var snippets: SyncRegister<CoreSnippetLibrary>
    public var habits: SyncRegister<CoreHabitLibrary>
    public var shelves: SyncRegister<CoreShelfConfiguration>
    public init(deviceID: UUID, generatedAt: Date = Date()) {
        self.deviceID = deviceID; self.generatedAt = generatedAt; context = SyncVector()
        note = SyncRegister(); settings = SyncRegister(); tasks = []
        launcherPins = SyncRegister(); workflows = SyncRegister(); palettes = SyncRegister()
        snippets = SyncRegister(); habits = SyncRegister(); shelves = SyncRegister()
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, deviceID, generatedAt, context, note, settings, tasks, launcherPins, workflows, palettes, snippets, habits, shelves }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...3).contains(version) else { throw SyncFailure.invalid("Unsupported sync snapshot version.") }
        schemaVersion = 3
        deviceID = try values.decode(UUID.self, forKey: .deviceID); generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        context = try values.decode(SyncVector.self, forKey: .context); note = try values.decode(SyncRegister<String>.self, forKey: .note)
        settings = try values.decode(SyncRegister<SyncSharedSettings>.self, forKey: .settings); tasks = try values.decode([SyncTaskRecord].self, forKey: .tasks)
        launcherPins = try values.decodeIfPresent(SyncRegister<[SyncLauncherPin]>.self, forKey: .launcherPins) ?? SyncRegister()
        workflows = try values.decodeIfPresent(SyncRegister<[WorkflowPreset]>.self, forKey: .workflows) ?? SyncRegister()
        palettes = try values.decodeIfPresent(SyncRegister<CoreColorPaletteLibrary>.self, forKey: .palettes) ?? SyncRegister()
        snippets = try values.decodeIfPresent(SyncRegister<CoreSnippetLibrary>.self, forKey: .snippets) ?? SyncRegister()
        habits = try values.decodeIfPresent(SyncRegister<CoreHabitLibrary>.self, forKey: .habits) ?? SyncRegister()
        shelves = try values.decodeIfPresent(SyncRegister<CoreShelfConfiguration>.self, forKey: .shelves) ?? SyncRegister()
    }
    public func visibleTasks() -> [ToDoItem] {
        tasks.compactMap { $0.item(on: deviceID) }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
    }
    public var conflictCount: Int { (note.hasConflict ? 1 : 0) + (settings.hasConflict ? 1 : 0) + tasks.filter(\.hasConflict).count
        + (launcherPins.hasConflict ? 1 : 0) + (workflows.hasConflict ? 1 : 0) + (palettes.hasConflict ? 1 : 0)
        + (snippets.hasConflict ? 1 : 0) + (habits.hasConflict ? 1 : 0) + (shelves.hasConflict ? 1 : 0) }
    public func portableLibrary() -> SyncPortableLibrary {
        SyncPortableLibrary(launcherPins: launcherPins.preferred(on: deviceID) ?? [], workflows: workflows.preferred(on: deviceID) ?? [], palettes: palettes.preferred(on: deviceID),
                            snippets: snippets.preferred(on: deviceID) ?? .init(), habits: habits.preferred(on: deviceID) ?? .init(), shelves: shelves.preferred(on: deviceID) ?? .init())
    }
    public mutating func capturePortable(_ value: SyncPortableLibrary, at date: Date = Date(), resolve: SyncPortableSection? = nil) throws {
        try value.validate(); var next = self
        if (launcherPins.preferred(on: deviceID) != value.launcherPins && !(launcherPins.revisions.isEmpty && value.launcherPins.isEmpty)) || resolve == .launcher {
            try next.context.advance(deviceID); next.launcherPins.set(value.launcherPins, device: deviceID, at: date, clock: next.context)
        }
        if (workflows.preferred(on: deviceID) != value.workflows && !(workflows.revisions.isEmpty && value.workflows.isEmpty)) || resolve == .workflows {
            try next.context.advance(deviceID); next.workflows.set(value.workflows, device: deviceID, at: date, clock: next.context)
        }
        if (palettes.preferred(on: deviceID) != value.palettes && !(palettes.revisions.isEmpty && value.palettes.palettes.isEmpty)) || resolve == .palettes {
            try next.context.advance(deviceID); next.palettes.set(value.palettes, device: deviceID, at: date, clock: next.context)
        }
        if (snippets.preferred(on: deviceID) != value.snippets && !(snippets.revisions.isEmpty && value.snippets.snippets.isEmpty)) || resolve == .snippets {
            try next.context.advance(deviceID); next.snippets.set(value.snippets, device: deviceID, at: date, clock: next.context)
        }
        if (habits.preferred(on: deviceID) != value.habits && !(habits.revisions.isEmpty && value.habits.habits.isEmpty)) || resolve == .habits {
            try next.context.advance(deviceID); next.habits.set(value.habits, device: deviceID, at: date, clock: next.context)
        }
        if (shelves.preferred(on: deviceID) != value.shelves && !(shelves.revisions.isEmpty && value.shelves == CoreShelfConfiguration())) || resolve == .shelves {
            try next.context.advance(deviceID); next.shelves.set(value.shelves, device: deviceID, at: date, clock: next.context)
        }
        next.schemaVersion = 3; next.generatedAt = date; try next.validate(); self = next
    }
    public mutating func captureNote(_ text: String, at date: Date = Date(), resolve: Bool = false) throws {
        guard text.utf8.count <= 200_000 else { throw SyncFailure.invalid("Synced notes are limited to 200 KB. Local original was not changed.") }
        if note.preferred(on: deviceID) == text && !resolve { return }
        if note.revisions.isEmpty && text.isEmpty { return }
        var next = context; try next.advance(deviceID); context = next
        note.set(text, device: deviceID, at: date, clock: context); generatedAt = date
    }
    public mutating func captureSettings(_ value: SyncSharedSettings, at date: Date = Date(), resolve: Bool = false) throws {
        try value.validate()
        if settings.preferred(on: deviceID) == value && !resolve { return }
        var next = context; try next.advance(deviceID); context = next
        settings.set(value, device: deviceID, at: date, clock: context); generatedAt = date
    }
    public mutating func captureTasks(_ items: [ToDoItem], at date: Date = Date()) throws {
        var candidate = self
        try candidate.captureTasksInPlace(items, at: date)
        self = candidate
    }
    private mutating func captureTasksInPlace(_ items: [ToDoItem], at date: Date) throws {
        guard items.count <= 1_000, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 500 }) else {
            throw SyncFailure.invalid("Invalid task list; use at most 1,000 tasks and 500 characters per task.")
        }
        let ids = Set(items.map(\.id))
        for index in tasks.indices where !tasks[index].isDeleted && !ids.contains(tasks[index].id) {
            try context.advance(deviceID); tasks[index].deleted.set(true, device: deviceID, at: date, clock: context)
        }
        for item in items {
            if let index = tasks.firstIndex(where: { $0.id == item.id }) {
                // Stale UI edits cannot resurrect a task deleted on another Mac.
                guard !tasks[index].isDeleted else { continue }
                if tasks[index].title.preferred(on: deviceID) != item.title { try context.advance(deviceID); tasks[index].title.set(item.title, device: deviceID, at: date, clock: context) }
                if tasks[index].completed.preferred(on: deviceID) != item.completed { try context.advance(deviceID); tasks[index].completed.set(item.completed, device: deviceID, at: date, clock: context) }
                if tasks[index].starred.preferred(on: deviceID) != item.starred { try context.advance(deviceID); tasks[index].starred.set(item.starred, device: deviceID, at: date, clock: context) }
            } else {
                try context.advance(deviceID)
                tasks.append(SyncTaskRecord(id: item.id, createdAt: item.createdAt,
                    title: SyncRegister([SyncRevision(deviceID: deviceID, writtenAt: date, clock: context, value: item.title)]),
                    completed: SyncRegister([SyncRevision(deviceID: deviceID, writtenAt: date, clock: context, value: item.completed)]),
                    starred: SyncRegister([SyncRevision(deviceID: deviceID, writtenAt: date, clock: context, value: item.starred)]),
                    deleted: SyncRegister([SyncRevision(deviceID: deviceID, writtenAt: date, clock: context, value: false)])))
            }
        }
        generatedAt = date; try validate()
    }
    public func validate() throws {
        guard (1...3).contains(schemaVersion), tasks.count <= 2_000, Set(tasks.map(\.id)).count == tasks.count,
              generatedAt.timeIntervalSince1970.isFinite,
              (-62_135_596_800...253_402_300_799).contains(generatedAt.timeIntervalSince1970) else {
            throw SyncFailure.invalid("Unsupported sync version or excessive task/tombstone records.")
        }
        try context.validate(); try note.validate(context: context); try settings.validate(context: context)
        try launcherPins.validate(context: context); try workflows.validate(context: context); try palettes.validate(context: context)
        try snippets.validate(context: context); try habits.validate(context: context); try shelves.validate(context: context)
        for revision in launcherPins.revisions { try SyncLauncherPin.validate(revision.value) }
        for revision in workflows.revisions { try SyncPortableLibrary(workflows: revision.value).validate() }
        for revision in palettes.revisions { _ = try revision.value.encoded() }
        for revision in snippets.revisions { _ = try SyncPortableLibrary(snippets: revision.value).validate() }
        for revision in habits.revisions { _ = try revision.value.encoded() }
        for revision in shelves.revisions { _ = try revision.value.encoded() }
        for revision in note.revisions where revision.value.utf8.count > 200_000 { throw SyncFailure.invalid("A shared note exceeds 200 KB; local originals are preserved.") }
        for revision in settings.revisions { try revision.value.validate() }
        for task in tasks {
            guard task.createdAt.timeIntervalSince1970.isFinite, !task.title.revisions.isEmpty,
                  !task.completed.revisions.isEmpty, !task.starred.revisions.isEmpty, !task.deleted.revisions.isEmpty,
                  task.title.revisions.allSatisfy({ !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value.count <= 500 }) else {
                throw SyncFailure.invalid("Invalid shared task data.")
            }
            try task.title.validate(context: context); try task.completed.validate(context: context)
            try task.starred.validate(context: context); try task.deleted.validate(context: context)
        }
        guard visibleTasks().count <= 1_000 else { throw SyncFailure.invalid("Merged active task list exceeds 1,000 tasks; nothing was replaced.") }
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw SyncFailure.invalid("Sync file exceeds 8 MB; local originals are preserved.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    public func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw SyncFailure.invalid("Sync state exceeds 8 MB; syncing is paused.") }
        return data
    }
}

public enum SyncMerge {
    /// Local edits are generated against the base context; concurrent remote edits survive as variants.
    public static func threeWay(base: SyncSnapshot, local: SyncSnapshot, remote: SyncSnapshot) throws -> SyncSnapshot {
        try base.validate(); try local.validate(); try remote.validate()
        var result = local
        result.context.observe(base.context); result.context.observe(remote.context)
        result.note = try local.note.merged(with: base.note).merged(with: remote.note)
        result.settings = try local.settings.merged(with: base.settings).merged(with: remote.settings)
        result.launcherPins = try local.launcherPins.merged(with: base.launcherPins).merged(with: remote.launcherPins)
        result.workflows = try local.workflows.merged(with: base.workflows).merged(with: remote.workflows)
        result.palettes = try local.palettes.merged(with: base.palettes).merged(with: remote.palettes)
        result.snippets = try local.snippets.merged(with: base.snippets).merged(with: remote.snippets)
        result.habits = try local.habits.merged(with: base.habits).merged(with: remote.habits)
        result.shelves = try local.shelves.merged(with: base.shelves).merged(with: remote.shelves)
        var tasks: [UUID: SyncTaskRecord] = [:]
        for task in base.tasks + local.tasks + remote.tasks {
            tasks[task.id] = try tasks[task.id].map { try $0.merged(with: task) } ?? task
        }
        result.tasks = tasks.values.sorted { $0.id.uuidString < $1.id.uuidString }
        result.generatedAt = Date(); try result.validate(); return result
    }
}
