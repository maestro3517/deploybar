import SwiftUI
import AppKit

/// "Deploy started" popover that drops out of the menu bar icon, then closes itself.
/// Uses `.applicationDefined` so it never takes focus and outside clicks leave it alone.
@MainActor
final class StartAlert {
    static let shared = StartAlert()
    private var popover: NSPopover?
    private var deploys: [Deploy] = []
    private var closeTask: Task<Void, Never>?
    private var warned = false

    func show(_ new: [Deploy], store: Store) {
        let merged = Array((new + deploys.filter { d in !new.contains { $0.id == d.id } }).prefix(3))
        if let popover {
            deploys = merged
            popover.contentViewController = host(store)
        } else {
            guard let anchor = NSApp.windows.first(where: { $0.className.contains("NSStatusBarWindow") && $0.isVisible }),
                  let view = anchor.contentView else {
                if !warned { warned = true; NSLog("DeployBar: no menu bar window found, start alert skipped") }
                return
            }
            deploys = merged
            let p = NSPopover()
            p.behavior = .applicationDefined
            p.animates = true
            p.contentViewController = host(store)
            popover = p
            p.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        restartTimer(10)
    }

    private func host(_ store: Store) -> NSViewController {
        NSHostingController(rootView: StartAlertView(
            deploys: deploys, store: store,
            onClose: { [weak self] in self?.close() },
            onHover: { [weak self] inside in
                if inside { self?.closeTask?.cancel() } else { self?.restartTimer(4) }
            }))
    }

    private func restartTimer(_ seconds: UInt64) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if !Task.isCancelled { self?.close() }
        }
    }

    private func close() {
        closeTask?.cancel()
        popover?.performClose(nil)
        popover = nil
        deploys = []
    }
}

struct StartAlertView: View {
    let deploys: [Deploy]
    @ObservedObject var store: Store
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    private func typical(_ d: Deploy) -> TimeInterval? {
        store.groups.flatMap(\.apps).first { $0.id == "\(d.provider.rawValue)/\(d.project)" }?.typicalDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hammer.fill").font(.system(size: 12)).foregroundStyle(.orange)
                Text("Deploy started").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            ForEach(Array(deploys.enumerated()), id: \.element.id) { i, d in
                if i > 0 { Divider() }
                DeployButton(deploy: d, label: "\(d.project) on \(d.provider.displayName) started",
                             action: {
                                 if let url = d.url { NSWorkspace.shared.open(url) }
                                 onClose()
                             }) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(d.project).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            ProviderMark(provider: d.provider)
                            if !d.isProduction { PreviewTag() }
                        }
                        Text(d.message ?? "No commit message").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Text([d.branch, d.commit].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        FlatProgress(deploy: d, typical: typical(d))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onHover(perform: onHover)
    }
}

/// Flat bar for an active deploy: fills against the app's typical build time, else shows state and elapsed time.
private struct FlatProgress: View {
    let deploy: Deploy
    let typical: TimeInterval?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = max(0, ctx.date.timeIntervalSince(deploy.createdAt))
            let t = typical ?? 0
            let fraction = t > 0 ? min(elapsed / t, 0.99) : 0
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        if t > 0 {
                            Capsule().fill(deploy.provider.badgeColor).frame(width: g.size.width * fraction)
                        }
                    }
                }
                .frame(height: 5)
                .animation(.linear(duration: 1), value: fraction)
                if t > 0 {
                    HStack(spacing: 6) {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                        Text(elapsed < t
                             ? "About \(Fmt.duration(t - elapsed)) left"
                             : "Taking longer than usual · \(Fmt.duration(elapsed))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(deploy.state.label) · \(Fmt.duration(elapsed))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
