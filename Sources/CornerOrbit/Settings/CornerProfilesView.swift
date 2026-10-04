import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CornerCore

@MainActor
struct CornerProfilesView: View {
    @ObservedObject var profiles: CornerProfilesStore
    let currentSettings: CornerSettings
    @ObservedObject var timedPause: CornerTimedPauseController
    @ObservedObject var login: CornerLaunchAtLoginService
    @State private var selectedID: UUID?
    @State private var name = ""
    @State private var ruleApp = ""
    @State private var ruleProfileID: UUID?
    @State private var editingRuleID: UUID?
    @State private var excludedApp = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Profiles and controls").font(.title3.weight(.semibold))
                profileSection
                if profiles.needsRecovery {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved profile data was retained. Reset explicitly preserves it beside a new empty profile file.").font(.caption)
                        Button("Preserve and Reset Profiles") { perform { try profiles.preserveAndReset() } }
                    }
                }
                ruleSection
                excludedSection
                pauseSection
                loginSection
                if let error = profiles.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(20)
        }.sheet(isPresented: Binding(get: { profiles.importPreview != nil }, set: { if !$0 { profiles.cancelImport() } })) {
            if let preview = profiles.importPreview { CornerProfileImportReview(profiles: profiles, preview: preview) }
        }
    }
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved binding profiles", systemImage: "square.stack.3d.up").font(.headline)
            if profiles.profiles.isEmpty { Text("Create a named snapshot of your current corner bindings.").foregroundStyle(.secondary).font(.caption) }
            else {
                VStack(spacing: 6) {
                    ForEach(profiles.profiles) { profile in
                        Button { selectedID = profile.id; name = profile.name } label: {
                            HStack {
                                Image(systemName: selectedID == profile.id ? "checkmark.circle.fill" : "circle")
                                Text(profile.name).fontWeight(.medium)
                                Spacer()
                                if profiles.activeProfileID == profile.id { Text("Active").font(.caption).foregroundStyle(.tint) }
                                Text("\(configuredCount(profile)) actions").font(.caption).foregroundStyle(.secondary)
                            }.padding(9).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel("\(profile.name), \(configuredCount(profile)) configured actions")
                    }
                }
            }
            TextField("Profile name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("Create from Current") { perform { selectedID = try profiles.create(name: name, settings: currentSettings) } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Rename") { guard let selectedID else { return }; perform { try profiles.rename(id: selectedID, name: name) } }.disabled(selectedID == nil)
                Button("Duplicate") { guard let selectedID else { return }; perform { self.selectedID = try profiles.duplicate(id: selectedID) } }.disabled(selectedID == nil)
                Button("Delete", role: .destructive) { guard let selectedID else { return }; perform { try profiles.delete(id: selectedID); self.selectedID = nil } }.disabled(selectedID == nil)
            }
            HStack {
                Button("Apply Profile") { guard let selectedID else { return }; perform { try profiles.activate(id: selectedID) } }.disabled(selectedID == nil)
                Button("Update from Current") { guard let selectedID else { return }; perform { try profiles.saveSnapshot(id: selectedID, settings: currentSettings) } }.disabled(selectedID == nil)
                Spacer()
                Button("Import JSON…", action: profiles.chooseImport)
                Button("Export JSON…", action: profiles.chooseExport).disabled(profiles.profiles.isEmpty)
            }
            Text("Profiles store bindings and gesture settings. Applying one preserves your current monitoring choice; imports are reviewed before adding snapshots.").font(.caption).foregroundStyle(.secondary)
        }.disabled(profiles.needsRecovery || profiles.isPreview)
    }
    private var ruleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Select profiles for the frontmost app", isOn: Binding(get: { profiles.autoSwitchEnabled }, set: { value in perform { try profiles.setAutoSwitchEnabled(value) } })).font(.headline)
            Text("Rules are checked in order. Apps with no matching enabled rule retain the current profile. CornerOrbit ignores its own settings app.").font(.caption).foregroundStyle(.secondary)
            ForEach(profiles.rules) { rule in
                HStack(spacing: 8) {
                    Toggle("Use rule", isOn: Binding(get: { rule.enabled }, set: { value in var copy = rule; copy.enabled = value; perform { try profiles.updateRule(copy) } })).labelsHidden()
                    VStack(alignment: .leading) {
                        Text(rule.bundleID).font(.caption.monospaced()).textSelection(.enabled)
                        Text(profiles.profiles.first { $0.id == rule.profileID }?.name ?? "Missing profile").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { perform { try profiles.moveRule(id: rule.id, by: -1) } } label: { Image(systemName: "arrow.up") }.accessibilityLabel("Move rule earlier")
                    Button { perform { try profiles.moveRule(id: rule.id, by: 1) } } label: { Image(systemName: "arrow.down") }.accessibilityLabel("Move rule later")
                    Button("Edit") { editingRuleID = rule.id; ruleApp = rule.bundleID; ruleProfileID = rule.profileID }
                    Button("Delete") { perform { try profiles.deleteRule(id: rule.id) } }
                }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                TextField("Application bundle identifier", text: $ruleApp).textFieldStyle(.roundedBorder)
                Button("Choose App…") { chooseApplication { ruleApp = $0 } }
            }
            HStack {
                Picker("Profile", selection: $ruleProfileID) {
                    Text("Choose a profile").tag(Optional<UUID>.none)
                    ForEach(profiles.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                Button(editingRuleID == nil ? "Add Rule" : "Save Rule") { saveRule() }.disabled(ruleProfileID == nil || ruleApp.isEmpty)
                if editingRuleID != nil { Button("Cancel Edit") { editingRuleID = nil; ruleApp = ""; ruleProfileID = nil } }
            }
        }.disabled(profiles.needsRecovery || profiles.isPreview)
    }
    private var excludedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Excluded applications", systemImage: "hand.raised").font(.headline)
            Text("Corner gestures pause while an excluded app is frontmost. Clearing the list stops exclusion observation when profile switching is also off.").font(.caption).foregroundStyle(.secondary)
            ForEach(profiles.excludedAppIDs.sorted(), id: \.self) { identifier in
                HStack { Text(identifier).font(.caption.monospaced()); Spacer(); Button("Remove") { perform { try profiles.setExcludedAppIDs(profiles.excludedAppIDs.subtracting([identifier])) } } }
            }
            HStack {
                TextField("Excluded app bundle identifier", text: $excludedApp).textFieldStyle(.roundedBorder)
                Button("Choose App…") { chooseApplication { excludedApp = $0 } }
                Button("Add") { perform { try profiles.setExcludedAppIDs(profiles.excludedAppIDs.union([excludedApp])); excludedApp = "" } }.disabled(excludedApp.isEmpty)
            }
        }.disabled(profiles.needsRecovery || profiles.isPreview)
    }
    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Timed pause", systemImage: "pause.circle").font(.headline)
            HStack {
                ForEach([5, 15, 60], id: \.self) { minutes in Button("\(minutes) min") { timedPause.pause(minutes: minutes) } }
                if let until = timedPause.until { Spacer(); Text(until, style: .timer).monospacedDigit(); Button("Resume Now", action: timedPause.resumeNow) }
            }
            Text("Timer expiry resumes only your previously enabled, authorized monitoring session. Turning monitoring off cancels automatic resume.").font(.caption).foregroundStyle(.secondary)
            if let error = timedPause.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }.disabled(profiles.isPreview)
    }
    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch CornerOrbit at login", isOn: Binding(get: { login.enabled || login.requiresApproval }, set: { value in Task { await login.setEnabled(value) } })).font(.headline).disabled(login.isPreview)
            Text(login.statusMessage).font(.caption).foregroundStyle(.secondary)
            if login.requiresApproval { Button("Open Login Items", action: login.openApprovalSettings) }
            if let error = login.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func configuredCount(_ profile: CornerProfile) -> Int { profile.settings.corners.values.reduce(0) { $0 + $1.bindings.values.filter { $0.kind != .none }.count } }
    private func perform(_ operation: () throws -> Void) { do { try operation() } catch { profiles.report(error: error) } }
    private func saveRule() {
        guard let ruleProfileID else { return }
        perform {
            if let editingRuleID, var rule = profiles.rules.first(where: { $0.id == editingRuleID }) {
                rule.bundleID = ruleApp; rule.profileID = ruleProfileID; try profiles.updateRule(rule)
            } else { try profiles.addRule(bundleID: ruleApp, profileID: ruleProfileID) }
            editingRuleID = nil; ruleApp = ""; self.ruleProfileID = nil
        }
    }
    private func chooseApplication(_ selected: (String) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { profiles.report(error: CornerActionError.invalid("This application has no bundle identifier.")); return }
        selected(identifier)
    }
}

@MainActor
struct CornerProfileImportReview: View {
    @ObservedObject var profiles: CornerProfilesStore
    let preview: CornerProfileImportPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review \(preview.count) imported profiles").font(.title2.weight(.semibold))
            Text("Only snapshots will be added. Monitoring, Automation, launch at login, app rules, and exclusions are not enabled by importing.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(preview.importedProfiles) { profile in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile.name).font(.headline)
                            Text("Click interval \(profile.settings.clickInterval.formatted()) s · Hover \(profile.settings.hoverDelay.formatted()) s · Hold \(profile.settings.holdDelay.formatted()) s · Drag threshold \(Int(profile.settings.dragThreshold)) pt · Cooldown \(profile.settings.cooldown.formatted()) s").font(.caption).foregroundStyle(.secondary)
                            Text(profile.settings.enabledDisplayIDs.isEmpty ? "Displays: All" : "Displays: " + profile.settings.enabledDisplayIDs.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            ForEach(Corner.allCases, id: \.self) { corner in
                                Text("\(corner.title): \(Int(profile.settings.size(for: corner))) pt · \(modifierLabel(profile.settings.requiredModifiers(for: corner)))").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                ForEach(CornerGesture.allCases, id: \.self) { gesture in
                                    let action = profile.settings.corners[corner]?.action(for: gesture) ?? .none
                                    if action.kind != .none {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(corner.title) · \(gesture.title) → \(action.kind.title)").font(.callout)
                                            if profile.settings.corners[corner]?.enabled == false { Text("This corner is disabled in the snapshot.").font(.caption).foregroundStyle(.secondary) }
                                            ForEach(arguments(action), id: \.self) { argument in
                                                Text(argument).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                            }
                                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                        }
                    }
                    ForEach(preview.renamedProfiles, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = profiles.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Button("Cancel", action: profiles.cancelImport); Spacer(); Button("Add Reviewed Profiles") { do { try profiles.applyImport() } catch { profiles.report(error: error) } }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 700, height: 560)
    }
    private func arguments(_ action: CornerAction) -> [String] {
        var details: [String] = []
        if let url = action.url ?? action.kind.defaultURL?.absoluteString { details.append("Website: \(url)") }
        if let identifier = action.bundleID ?? action.kind.defaultBundleID { details.append("Application: \(identifier)") }
        if let argument = action.argument {
            let label: String
            switch action.parameterKind { case .file: label = "File or Folder"; case .shortcut: label = "Shortcut"; case .urlGroup: label = "Website Group"; default: label = "Parameter" }
            details.append("\(label): \(argument)")
        }
        return details
    }
    private func modifierLabel(_ modifiers: CornerModifiers) -> String {
        let names: [(CornerModifiers, String)] = [(.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
        let selected = names.filter { modifiers.contains($0.0) }.map(\.1)
        return selected.isEmpty ? "No modifier required" : selected.joined(separator: " + ")
    }
}
