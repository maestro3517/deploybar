import SwiftUI
import AppKit
import ServiceManagement

enum Fmt {
    static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    static let durationFormat: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        return f
    }()
    static func duration(_ seconds: TimeInterval) -> String {
        durationFormat.string(from: seconds) ?? "--"
    }
}

extension DeployState {
    var color: Color {
        switch self {
        case .ready: return .green
        case .failed: return .red
        case .building: return .orange
        case .queued: return .yellow
        case .canceled, .skipped: return .gray
        }
    }

    var label: String {
        switch self {
        case .ready: return "Deployed"
        case .failed: return "Failed"
        case .building: return "Building"
        case .queued: return "Queued"
        case .canceled: return "Canceled"
        case .skipped: return "Skipped"
        }
    }
}

extension Provider {
    var badgeColor: Color {
        switch self {
        case .cloudflare: return Color(red: 0.96, green: 0.51, blue: 0.12)
        case .vercel: return .primary
        case .azure: return Color(red: 0.0, green: 0.47, blue: 0.84)
        }
    }
    var badgeSymbol: String {
        switch self {
        case .cloudflare: return "cloud.fill"
        case .vercel: return "triangle.fill"
        case .azure: return "infinity"
        }
    }
}

/// Header, auto-sized scroll area and footer.
struct MenuShell<Content: View>: View {
    @ObservedObject var store: Store
    @ViewBuilder var content: Content
    // A ScrollView in a menu bar window has no height of its own and collapses to zero, so size it to its content.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeader(store: store)
            Divider()
            ScrollView {
                content
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(listHeight, 40), 560))
            .onPreferenceChange(HeightKey.self) { listHeight = $0 }
            Divider()
            MenuFooter(store: store)
        }
        .frame(width: 400)
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    var body: some View { MenuShell(store: store) { BoardView(store: store) } }
}

struct MenuHeader: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("DeployBar").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(health.color).frame(width: 7, height: 7)
                    Text(health.text).foregroundStyle([.green, .gray].contains(health.color) ? Color.secondary : health.color)
                    if store.lastUpdated != nil {
                        Text("·").foregroundStyle(.tertiary)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(updatedText(ctx.date)).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
            }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                if store.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.loading)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// One line that answers "is everything OK?" before any row is read.
    private var health: (text: String, color: Color) {
        if store.lastUpdated == nil { return ("Checking deploys", .gray) }
        let failing = store.groups.flatMap(\.apps).filter { $0.latest.state == .failed }.count
        if store.activeCount > 0 { return ("\(store.activeCount) building", .orange) }
        if failing > 0 { return ("\(failing) failing", .red) }
        return (store.deploys.isEmpty ? "No deploys" : "All deploys healthy", .green)
    }

    private func updatedText(_ now: Date) -> String {
        guard let t = store.lastUpdated else { return "loading" }
        if now.timeIntervalSince(t) < 10 { return "updated just now" }
        return "updated " + Fmt.rel.localizedString(for: t, relativeTo: now)
    }
}

struct MenuFooter: View {
    @ObservedObject var store: Store
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.notificationsAllowed == false {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notifications are off").font(.caption.weight(.semibold))
                        Text("Turn them on to hear when a deploy finishes.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Turn On…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=one.tijarah.deploybar")!)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
            }
            ForEach(store.errors, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Toggle("Open at login", isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        loginStatus = SMAppService.mainApp.status
                    }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Accounts…") { SetupWindow.shared.show(store: store) }
                Button("Quit") { NSApp.terminate(nil) }
            }
            if loginStatus == .requiresApproval {
                Text("Approve DeployBar in System Settings > General > Login Items")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

/// Progress for an active deploy: a bar against the app's typical build time when known, else just elapsed time.
struct BuildProgress: View {
    let deploy: Deploy
    let typical: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = max(0, ctx.date.timeIntervalSince(deploy.createdAt))
            VStack(alignment: .leading, spacing: 3) {
                if let typical, typical > 0 {
                    ProgressView(value: min(elapsed / typical, 0.95))
                        .progressViewStyle(.linear)
                        .tint(deploy.state.color)
                        .controlSize(.small)
                    Text(elapsed < typical
                         ? "About \(Fmt.duration(typical - elapsed)) left"
                         : "Taking longer than usual · \(Fmt.duration(elapsed))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(deploy.state.label) · \(Fmt.duration(elapsed))")
                        .foregroundStyle(deploy.state.color)
                }
            }
            .font(.caption)
        }
    }
}

/// Outlined "Preview" tag for non-production deploys.
struct PreviewTag: View {
    var body: some View {
        Text("Preview")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2)))
            .fixedSize()
    }
}

/// Plain row button that opens a deploy's dashboard page, with hover tint, tooltip and one accessibility label.
struct DeployButton<Content: View>: View {
    let deploy: Deploy
    let label: String
    var hint: String? = nil
    /// Replaces "open the deploy's page" when set.
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hovering = false

    /// What the row leaves out: the commit, then where a click goes.
    private var tooltip: String {
        let commit = [deploy.branch, deploy.commit, deploy.message].compactMap { $0 }.joined(separator: " · ")
        let open = action != nil || deploy.url == nil ? nil : "Click to open in \(deploy.provider.displayName)"
        return [commit.isEmpty ? nil : commit, open].compactMap { $0 }.joined(separator: "\n")
    }

    var body: some View {
        Button {
            if let action { action() } else if let url = deploy.url { NSWorkspace.shared.open(url) }
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Color.primary.opacity(0.06) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil && deploy.url == nil)
        .onHover { hovering = $0 }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
    }
}

/// Small project heading above a group of rows.
struct MenuHeading: View {
    let text: String
    var top: CGFloat = 14
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, top).padding(.bottom, 4)
            .padding(.leading, 8)
    }
}

/// Provider logo stand-in: Cloudflare's orange cloud, Vercel's triangle.
struct ProviderMark: View {
    let provider: Provider
    var body: some View {
        Image(systemName: provider.badgeSymbol)
            .font(.system(size: provider == .vercel ? 8 : 10, weight: .semibold))
            .foregroundStyle(provider.badgeColor)
            .help(provider.displayName)
            .accessibilityLabel(provider.displayName)
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}


/// The menu: one line per app, grouped under project headings, with recent build times as bars.
struct BoardView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.groups.enumerated()), id: \.element.id) { i, g in
                MenuHeading(text: g.repo, top: i == 0 ? 0 : 12)
                ForEach(Array(g.apps.enumerated()), id: \.element.id) { j, app in
                    if j > 0 { Divider().opacity(0.5) }
                    BoardRow(app: app)
                }
            }
            if store.deploys.isEmpty && !store.loading {
                VStack(spacing: 6) {
                    if store.connected {
                        Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                        Text("No deploys yet").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "key.fill").font(.title2).foregroundStyle(.secondary)
                        Text("Connect Cloudflare or Vercel to see your deploys")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Set Up…") { SetupWindow.shared.show(store: store) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }
}

private struct BoardRow: View {
    let app: AppHistory
    @State private var showTimeline = false
    private var d: Deploy { app.latest }

    var body: some View {
        DeployButton(deploy: d, label: "\(d.project) on \(d.provider.displayName), \(d.state.label)",
                     hint: "Shows recent deploys", action: { showTimeline.toggle() }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Group {
                        if d.isActive { ProgressView().controlSize(.mini) } else { Circle().fill(d.state.color) }
                    }
                    .frame(width: 10, height: 10)
                    Text(d.project).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    ProviderMark(provider: d.provider)
                    if !d.isProduction { PreviewTag() }
                    Spacer(minLength: 8)
                    DurationBars(app: app)
                    // Re-render each second so "27 sec ago" keeps counting between fetches.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Fmt.rel.localizedString(for: d.createdAt, relativeTo: ctx.date))
                    }
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 52, alignment: .trailing)
                }
                if d.isActive {
                    BuildProgress(deploy: d, typical: app.typicalDuration).padding(.leading, 18)
                } else if d.state == .failed {
                    Text(d.message ?? "No commit message")
                        .font(.caption).foregroundStyle(Color.red.opacity(0.85)).lineLimit(1)
                        .padding(.leading, 18)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .popover(isPresented: $showTimeline, arrowEdge: .leading) { TimelinePopover(app: app) }
    }
}

/// Popover for one app: who it is, a way to open it, then its recent deploys.
struct TimelinePopover: View {
    let app: AppHistory
    var logPreview: [String]? = nil
    private var d: Deploy { app.latest }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(d.state.color).frame(width: 10, height: 10)
                Text(d.project).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                ProviderMark(provider: d.provider)
                if !d.isProduction { PreviewTag() }
                Spacer(minLength: 8)
                Button {
                    if let url = d.url { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open in \(d.provider.displayName)", systemImage: "arrow.up.right.square").font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(d.url == nil)
            }
            Divider()
            if d.state == .failed && (d.logURL != nil || logPreview != nil) {
                FailureLog(deploy: d, preview: logPreview)
                Divider()
            }
            AppTimeline(app: app)
        }
        .padding(12)
        .frame(width: 340)
    }
}

/// A failed deploy's build log tail plus a button that copies a ready-made prompt for an AI coding agent.
struct FailureLog: View {
    let deploy: Deploy
    var preview: [String]? = nil   // fixed lines for snapshots; skips the network
    @State private var lines: [String]? = nil
    @State private var error: String? = nil
    @State private var copied = false

    private var tail: String {
        let t = (lines ?? []).suffix(40)
        return t.isEmpty ? "No log lines" : t.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Build log", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.red)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(agentPrompt(deploy, log: lines ?? []), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy for AI", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(lines == nil && error == nil)
                .help("Copies the error and build log as a prompt for your AI coding agent")
            }
            if lines != nil {
                // Lines don't wrap, so compiler carets stay under the code they point at. Opens at the end, where the error is.
                ScrollView([.vertical, .horizontal]) {
                    Text(tail)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(6).padding(.bottom, 10)  // room for the horizontal scroller
                }
                .defaultScrollAnchor(.bottomLeading)
                .frame(maxWidth: .infinity).frame(height: 130)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            } else if let error {
                Text("Couldn't load the build log: \(error)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("Loading build log…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: deploy.id) {
            if let preview { lines = preview; return }
            do { lines = try await fetchBuildLog(deploy) } catch {
                let m = Mirror(reflecting: error).children.first { $0.label == "message" }?.value as? String
                self.error = m ?? error.localizedDescription
            }
        }
    }
}

/// An app's recent deploys, newest first, joined by a rail; each entry opens that deploy.
private struct AppTimeline: View {
    let app: AppHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(app.deploys.enumerated()), id: \.element.id) { i, d in
                entry(d, first: i == 0, last: i == app.deploys.count - 1)
            }
        }
    }

    private func day(_ d: Deploy) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d.createdAt) { return d.createdAt.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d.createdAt) { return "Yesterday" }
        return d.createdAt.formatted(.dateTime.month(.abbreviated).day())
    }

    private func outcome(_ d: Deploy) -> String? {
        let took = d.finishedAt.map { Fmt.duration($0.timeIntervalSince(d.createdAt)) }
        switch d.state {
        case .failed: return took.map { "Failed after \($0)" } ?? "Failed"
        case .canceled: return "Canceled"
        case .skipped: return "Skipped"
        default: return took
        }
    }

    private func entry(_ d: Deploy, first: Bool, last: Bool) -> some View {
        let nodeY: CGFloat = 12  // centre of the first text line: 4 pt padding + half a 12 pt line
        let label = "\(d.state.label), \(d.message ?? "No commit message"), \(Fmt.rel.localizedString(for: d.createdAt, relativeTo: Date()))"
        return DeployButton(deploy: d, label: label) {
            HStack(alignment: .top, spacing: 8) {
                Text(day(d))
                    .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    .lineLimit(1).frame(width: 58, alignment: .trailing)
                    .padding(.top, 6)
                Group {
                    if d.isActive { ProgressView().controlSize(.mini) } else { Circle().fill(d.state.color).frame(width: 7, height: 7) }
                }
                .frame(width: 10, height: 10).padding(.top, nodeY - 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.message ?? "No commit message")
                        .font(.system(size: 12, weight: first ? .medium : .regular))
                        .foregroundStyle(d.message == nil ? .tertiary : .primary).lineLimit(1)
                    if d.isActive {
                        BuildProgress(deploy: d, typical: app.typicalDuration)
                    } else {
                        meta(d).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            // The rail spans the whole entry so neighbours join; it stops at the first and last node.
            .background(alignment: .topLeading) {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    .padding(.top, first ? nodeY : 0)
                    .frame(maxHeight: last ? nodeY : .infinity, alignment: .top)
                    .padding(.leading, 58 + 8 + 4.5)
            }
        }
    }

    /// branch · commit · outcome, skipping what is missing.
    private func meta(_ d: Deploy) -> Text {
        var parts: [Text] = []
        if let b = d.branch { parts.append(Text(b)) }
        if let c = d.commit { parts.append(Text(c).font(.system(size: 10, design: .monospaced))) }
        if let o = outcome(d) { parts.append(Text(o)) }
        guard var t = parts.first else { return Text("") }
        for p in parts.dropFirst() { t = t + Text(" · ") + p }
        return t
    }
}

/// Build time of the last 8 deploys, oldest on the left. Real data: each bar's tooltip says which deploy it is.
private struct DurationBars: View {
    let app: AppHistory

    var body: some View {
        let ds = Array(app.deploys.prefix(8).reversed())
        let times = ds.map { d in d.finishedAt.map { $0.timeIntervalSince(d.createdAt) } }
        let longest = max(times.compactMap { $0 }.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(ds.enumerated()), id: \.element.id) { i, d in
                let newest = i == ds.count - 1
                let tip = "\(d.state.label) \(Fmt.rel.localizedString(for: d.createdAt, relativeTo: Date()))"
                    + (times[i].map { " · \(Fmt.duration($0))" } ?? "")
                Group {
                    if newest && d.isActive {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            let frac = app.typicalDuration.map { min(ctx.date.timeIntervalSince(d.createdAt) / $0, 1) } ?? 0
                            let pulse = Int(ctx.date.timeIntervalSinceReferenceDate) % 2 == 0
                            bar(d, height: max(3, 16 * frac), opacity: pulse ? 1 : 0.5)
                                .animation(.easeInOut(duration: 1), value: pulse)
                        }
                    } else {
                        bar(d, height: 3 + 13 * (times[i] ?? 0) / longest, opacity: newest ? 1 : 0.55)
                    }
                }
                .help(tip)
            }
        }
        .frame(height: 16)
        .accessibilityLabel("Build times of last \(ds.count) deploys")
    }

    private func bar(_ d: Deploy, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(d.state.color.opacity(opacity))
            .frame(width: 4, height: height)
    }
}
