import AppKit
import SwiftUI
import NotchCore

@MainActor
extension NotchAppDelegate {
    static func dashboardModules(chooseFiles: @escaping @MainActor () -> Void) -> [NotchDashboardModule] {
        PlusTool.defaultOrder.map { tool in
            NotchDashboardModule(id: tool.rawValue, title: tool == .assistant ? "Ask Orbit" : tool.title,
                                 symbol: tool.symbol) {
                switch tool {
                case .assistant: AnyView(AssistantToolView())
                case .aiUsage: AnyView(AIUsageToolView())
                case .sales: AnyView(SalesToolView())
                case .clipboard: AnyView(ClipboardToolView())
                case .teleprompter: AnyView(TeleprompterToolView())
                case .timers: AnyView(TimersToolView())
                case .fileShelf: AnyView(FileShelfToolView())
                case .mirror: AnyView(MirrorToolView())
                case .calendar: AnyView(CalendarToolView())
                case .reminders: AnyView(RemindersToolView())
                case .todos: AnyView(ToDosToolView())
                case .weather: AnyView(WeatherToolView())
                case .stocks: AnyView(StocksToolView())
                case .emoji: AnyView(EmojiToolView())
                case .converter: AnyView(ConverterToolView())
                case .system: AnyView(SystemToolView())
                case .quickNote: AnyView(QuickNoteToolView())
                case .nowPlaying: AnyView(NowPlayingToolView())
                case .shortcuts: AnyView(ShortcutsToolView())
                case .fileActions: AnyView(FileActionsToolView(chooseFiles: chooseFiles))
                }
            }
        }
    }
}

@MainActor
struct PlusCompactView: View {
    @ObservedObject private var timer = FocusTimerService.shared
    var body: some View {
        HStack(spacing: 8) {
            if let countdown = timer.compactText {
                Image(systemName: timer.timer.phase == .rest ? "cup.and.saucer" : "timer")
                Text(countdown).monospacedDigit()
                if timer.timer.isPaused { Image(systemName: "pause.fill").font(.system(size: 9)) }
            } else {
                Image(systemName: "rectangle.topthird.inset.filled")
                Text("NotchOrbitPlus")
            }
        }.font(.system(size: 11, weight: .medium))
    }
}

@MainActor
private struct FileActionsToolView: View {
    let chooseFiles: @MainActor () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("File actions", systemImage: "wand.and.stars").font(.headline)
            Text("Drag files toward the notch to open the original action semicircle. Hover a category, move to an action, and release there.")
            Text("Convert, compress and resize images; work with PDFs, audio and video; create ZIPs, duplicate files, generate checksums and format JSON.")
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: chooseFiles).buttonStyle(.borderedProminent)
            Text("Choosing files reveals them in Finder. Drag those same files onto an action to run it. Outputs are separate from the originals.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(12)
    }
}

@MainActor
struct PlusSettingsView: View {
    let model: AppModel
    @ObservedObject var dashboardPreferences: DashboardPreferences
    let requestAccess: () -> Void
    let applyPreferences: () -> Void
    var body: some View {
        TabView {
            DashboardSettingsView(preferences: dashboardPreferences)
                .tabItem { Label("Dashboard", systemImage: "rectangle.topthird.inset.filled") }
            NotchSettingsView(model: model, requestAccess: requestAccess, applyPreferences: applyPreferences)
                .tabItem { Label("File actions", systemImage: "wand.and.stars") }
            VStack(spacing: 16) {
                Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 56)).foregroundStyle(.blue)
                Text("NotchOrbitPlus").font(.title.weight(.semibold))
                Text("Twenty tools, below your notch.").font(.title3)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") · macOS 14+")
                    .foregroundStyle(.secondary)
                Text("Ask Orbit requires macOS 26 and Apple Intelligence. Connected services need their own setup.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Link("Report an issue or request a feature", destination: URL(string: "https://github.com/sknitd/orbit/issues/new")!)
                Link("Features and setup", destination: URL(string: "https://github.com/sknitd/orbit/tree/codex/orbitdrop/NotchOrbitPlus")!)
            }.padding(24).tabItem { Label("About", systemImage: "info.circle") }
        }.padding(12).frame(width: 700, height: 600)
            .onChange(of: dashboardPreferences.keyboardShortcutEnabled) { _, _ in applyPreferences() }
    }
}

@MainActor
struct PlusWelcomeView: View {
    let requestAccess: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 46)).foregroundStyle(.blue)
                Text("NotchOrbitPlus").font(.title.weight(.semibold))
                Text("Your tools, one notch away.").font(.title3)
                Text("Hover or click the compact strip below the notch to open your tools. Pin it while you write, read or work. On a display without a notch, use the top center.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Use ⌘⌃N to toggle the dashboard. Settings lets you choose a display, opening delay, tab order and visible tools.")
                    .font(.callout).multilineTextAlignment(.center)
                Divider()
                Text("Drag files toward the notch to open file actions without pressing a key. Input Monitoring is needed only for automatic file-drag detection.")
                    .font(.callout).multilineTextAlignment(.center)
                Button("Enable file-drag detection", action: requestAccess).buttonStyle(.borderedProminent)
                Text("Calendar, reminders, camera and player control ask for access when you connect them. Clipboard history starts only when you enable it. Online tools connect only on your request; credentials stay in this app's Keychain items.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Ask Orbit needs macOS 26 and Apple Intelligence. No cloud model is substituted on unsupported Macs.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(28)
        }.frame(width: 480, height: 510)
    }
}
