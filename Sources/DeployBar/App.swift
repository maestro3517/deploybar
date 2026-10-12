import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import Foundation

@main
enum Launcher {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run() ? 0 : 1) }
        if args.contains("--dump") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let (deploys, errors) = await Providers.fetchAll()
                let iso = ISO8601DateFormatter()
                for d in deploys {
                    print([d.provider.rawValue, d.state.rawValue, d.project, d.repo,
                           d.branch ?? "-", d.commit ?? "-", iso.string(from: d.createdAt),
                           d.finishedAt.map { "\(Int($0.timeIntervalSince(d.createdAt)))s" } ?? "-"].joined(separator: " "))
                }
                for e in errors { print("error: \(e)") }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if args.contains("--notify-test") {
            Notifier.shared.start()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let ok = await Notifier.shared.allowed()
                print("notifications allowed: \(ok)")
                if !ok { print("Turn on: System Settings > Notifications > DeployBar") }
                sem.signal()
            }
            sem.wait()
            let stamp = Int(Date().timeIntervalSince1970)
            Notifier.shared.post(Deploy(
                id: "notify-test-v-\(stamp)", provider: .vercel, project: "demo-site", repo: "demo-site",
                branch: "main", commit: "abc1234", message: "Simulated deploy from --notify-test",
                state: .ready, createdAt: Date(), url: URL(string: "https://vercel.com/dashboard"), isProduction: true))
            Notifier.shared.post(Deploy(
                id: "notify-test-c-\(stamp)", provider: .cloudflare, project: "demo-worker", repo: "demo-worker",
                branch: "feature/x", commit: "def5678", message: "Simulated failure from --notify-test",
                state: .failed, createdAt: Date(), url: URL(string: "https://dash.cloudflare.com/"), isProduction: false))
            let pair = [Deploy(id: "t", provider: .vercel, project: "p", repo: "p", branch: nil, commit: nil, message: nil,
                               state: .ready, createdAt: Date(), url: nil, isProduction: false)]
            let n = finishedTransitions(previous: ["t": .building], fresh: pair, firstLoad: false,
                                        since: Date(), alreadyNotified: []).count
            print("transitions found: \(n) (expect 1)")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: URL(fileURLWithPath: args[i + 1]), demo: args.contains("--demo"))
            exit(0)
        }
        DeployBarApp.main()
    }

    /// Renders the menu with live data (or `--demo` data) to light.png and dark.png, for the README and bug reports.
    @MainActor private static func snapshot(to dir: URL, demo: Bool) {
        _ = NSApplication.shared
        let store = demo ? Store(preview: Demo.deploys()) : Store()
        if !demo {
            let deadline = Date(timeIntervalSinceNow: 60)
            while store.lastUpdated == nil && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }
        }
        func render<V: View>(_ file: String, _ look: NSAppearance.Name, _ root: V) {
            let view = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: look)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: look)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = view
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            view.frame.size = view.fittingSize
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file))
        }
        let timelineApp = store.groups.flatMap(\.apps).first { $0.id == "vercel/storefront-web" }
        let startApp = store.groups.flatMap(\.apps).first { $0.id == "vercel/dashboard" }
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            render("\(name).png", look, ContentView(store: store))
            if demo, let timelineApp { render("timeline-\(name).png", look, TimelinePopover(app: timelineApp)) }
            if demo, let startApp {
                render("start-\(name).png", look, StartAlertView(deploys: [startApp.latest], store: store, onClose: {}, onHover: { _ in }))
            }
            if demo {
                render("setup-\(name).png", look, SetupView(store: store, onDone: {}, preview: [.vercel: .vercelCLI, .cloudflare: nil]))
            }
        }
    }
}

/// Deploys that just finished (ready or failed) and should notify.
func finishedTransitions(previous: [String: DeployState], fresh: [Deploy], firstLoad: Bool,
                         since: Date, alreadyNotified: Set<String>) -> [Deploy] {
    fresh.filter { d in
        guard d.state == .ready || d.state == .failed, !alreadyNotified.contains(d.id) else { return false }
        switch previous[d.id] {
        case .queued?, .building?: return true
        case nil: return !firstLoad && d.createdAt >= since
        default: return false
        }
    }
}

/// Deploys that started since the last poll: active and never seen before. Nothing on first load.
func startedDeploys(previous: [String: DeployState], fresh: [Deploy], firstLoad: Bool) -> [Deploy] {
    firstLoad ? [] : fresh.filter { $0.isActive && previous[$0.id] == nil }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("DeployBar notifications: %@", "\(error)") }
        }
    }

    func post(_ d: Deploy) {
        let c = UNMutableNotificationContent()
        c.title = d.state == .ready ? "\(d.project) deployed on \(d.provider.displayName)"
                                    : "\(d.project) failed on \(d.provider.displayName)"
        c.subtitle = (d.isProduction ? "Production" : "Preview") + (d.branch.map { " · \($0)" } ?? "")
        let body = [d.commit, d.message].compactMap { $0 }.joined(separator: " · ")
        c.body = body.isEmpty ? "No commit message" : body
        c.sound = .default
        c.threadIdentifier = d.project
        c.userInfo = ["url": d.url?.absoluteString ?? ""]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "\(d.id)-\(d.state.rawValue)", content: c, trigger: nil)) { error in
            if let error { NSLog("DeployBar notifications: %@", "\(error)") }
        }
    }

    func allowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    // A menu bar app counts as foreground while its window is open; show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, !s.isEmpty, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

/// One worker / Pages project / Vercel project and its recent deploys, newest first.
struct AppHistory: Identifiable {
    let deploys: [Deploy]
    var latest: Deploy { deploys[0] }
    var id: String { "\(latest.provider.rawValue)/\(latest.project)" }
    /// Median build time of earlier successful deploys; nil with fewer than 2 samples.
    var typicalDuration: TimeInterval? {
        let s = deploys.dropFirst().filter { $0.state == .ready }
            .compactMap { d in d.finishedAt.map { $0.timeIntervalSince(d.createdAt) } }.sorted()
        return s.count < 2 ? nil : s[s.count / 2]
    }
}

struct RepoGroup: Identifiable {
    let repo: String  // the project heading
    let apps: [AppHistory]
    var id: String { repo }
}

/// Optional grouping of repos/apps under one heading, from
/// ~/Library/Application Support/DeployBar/projects.json:
/// [{"name": "Shop", "match": ["shop-web", "shop-api"]}]. Unlisted apps get their own heading.
let projectMap: [(name: String, keys: [String])] = {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DeployBar/projects.json")
    guard let data = try? Data(contentsOf: url),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return list.compactMap { e in
        guard let name = e["name"] as? String, let keys = e["match"] as? [String] else { return nil }
        return (name, keys.map { $0.lowercased() })
    }
}()

func projectName(for d: Deploy) -> String {
    let hay = (d.repo + " " + d.project).lowercased()
    return projectMap.first { $0.keys.contains { hay.contains($0) } }?.name ?? d.repo
}

@MainActor
final class Store: ObservableObject {
    @Published var deploys: [Deploy] = []
    @Published var errors: [String] = []
    @Published var lastUpdated: Date?
    @Published var loading = false
    /// nil until known; false means macOS blocks DeployBar's notifications.
    @Published var notificationsAllowed: Bool?
    /// False when no provider has a token yet.
    @Published var connected = true
    private var pollTask: Task<Void, Never>?
    private var known: [String: DeployState] = [:]
    private var notified = Set<String>()
    private var firstLoad = true
    private let launchedAt = Date()

    init() {
        Notifier.shared.start()
        pollTask = Task { [weak self] in
            while true {
                guard let self else { return }
                await self.refresh()
                // 30 s idle so most builds are still running when we first see them (start alert).
                let delay: UInt64 = self.deploys.contains { $0.isActive } ? 15 : 30
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
        // The poll clock pauses while the Mac sleeps; check right away on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
        if CommandLine.arguments.contains("--start-test") {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                StartAlert.shared.show([Deploy(
                    id: "start-test-\(Int(Date().timeIntervalSince1970))", provider: .vercel, project: "demo-site", repo: "demo-site",
                    branch: "main", commit: "abc1234", message: "Simulated start from --start-test", state: .building,
                    createdAt: Date(timeIntervalSinceNow: -20), url: URL(string: "https://vercel.com/dashboard"), isProduction: true)],
                    store: self)
            }
        }
    }

    /// Fixed data for `--snapshot --demo`: no polling, no notifications.
    init(preview: [Deploy]) {
        deploys = preview
        lastUpdated = Date()
        notificationsAllowed = true
    }

    var activeCount: Int { deploys.filter(\.isActive).count }

    var menuBarSymbol: String {
        if activeCount > 0 { return "arrow.triangle.2.circlepath" }
        let newest = Dictionary(grouping: deploys) { "\($0.provider.rawValue)/\($0.project)" }
            .values.compactMap { $0.max { $0.createdAt < $1.createdAt } }
            .filter { $0.createdAt > Date(timeIntervalSinceNow: -86400) }  // old failures stop flagging after a day
        return newest.contains { $0.state == .failed } ? "xmark.octagon" : "checkmark.icloud"
    }

    var groups: [RepoGroup] {
        Dictionary(grouping: deploys.sorted { $0.createdAt > $1.createdAt }, by: projectName(for:))
            .map { name, ds in
                // Dictionary(grouping:) keeps the newest-first order inside each app.
                let apps = Dictionary(grouping: ds) { "\($0.provider.rawValue)/\($0.project)" }.values
                    .map { AppHistory(deploys: Array($0.prefix(8))) }
                    .sorted { $0.latest.createdAt > $1.latest.createdAt }
                return RepoGroup(repo: name, apps: Array(apps.prefix(4)))
            }
            .sorted { $0.apps[0].latest.createdAt > $1.apps[0].latest.createdAt }
            .prefix(4)
            .map { $0 }
    }

    func refresh() async {
        loading = true
        let (fresh, errs) = await Providers.fetchAll()
        for d in finishedTransitions(previous: known, fresh: fresh, firstLoad: firstLoad, since: launchedAt, alreadyNotified: notified) {
            Notifier.shared.post(d); notified.insert(d.id)
        }
        let started = startedDeploys(previous: known, fresh: fresh, firstLoad: firstLoad)
        if !started.isEmpty { StartAlert.shared.show(started, store: self) }
        for d in fresh { known[d.id] = d.state }  // merge, never clear: a failed fetch must not forget builds in flight
        connected = Providers.anyConnected
        if firstLoad && !connected && !CommandLine.arguments.contains("--snapshot") { SetupWindow.shared.show(store: self) }
        firstLoad = false
        notificationsAllowed = await Notifier.shared.allowed()
        deploys = fresh
        errors = errs
        lastUpdated = Date()
        loading = false
    }
}

struct DeployBarApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: store.menuBarSymbol)
                if store.activeCount > 0 { Text("\(store.activeCount)") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
