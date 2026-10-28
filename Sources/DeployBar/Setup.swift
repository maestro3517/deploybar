import SwiftUI
import AppKit

/// Owns the one setup window. Kept around so reopening just brings it forward.
@MainActor final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?

    func show(store: Store) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Set Up DeployBar"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SetupView(store: store, onDone: { [weak self] in self?.window?.close() }))
            w.center()
            window = w
        }
        // The menu panel floats above normal windows, so close it or it covers the setup window.
        NSApp.windows.filter { $0.className.contains("MenuBarExtraWindow") && $0.isVisible }.forEach { $0.close() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SetupView: View {
    @ObservedObject var store: Store
    let onDone: () -> Void
    let preview: [Provider: TokenSource?]?

    init(store: Store, onDone: @escaping () -> Void, preview: [Provider: TokenSource?]? = nil) {
        self.store = store
        self.onDone = onDone
        self.preview = preview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect your deploys").font(.title2.weight(.semibold))
                        Text("Paste a read-only token for each platform you use. Skip the ones you don't.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(Provider.allCases, id: \.self) { p in
                    ProviderCard(provider: p, store: store, source: preview?[p] ?? p.tokenSource)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your tokens stay on this Mac").font(.subheadline.weight(.semibold))
                        Text("DeployBar saves them in your macOS Keychain and sends them only to api.cloudflare.com, api.vercel.com and dev.azure.com. There is no DeployBar server, no account and no analytics. Read-only tokens are enough.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .cardStyle(Color.green.opacity(0.06))

                HStack {
                    Spacer()
                    if store.connected {  // not Providers.anyConnected: that reads the Keychain on every render
                        Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done", action: onDone)
                    }
                }
            }
            .padding(20)
            .frame(width: 460)
        }
        .frame(height: 700)  // ScrollView has no ideal height; without a fixed one the window opens with no content
    }
}

private struct ProviderCard: View {
    let provider: Provider
    let store: Store
    @State private var source: TokenSource?
    @State private var editing = false
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?
    @State private var org = ""
    @State private var project = ""

    init(provider: Provider, store: Store, source: TokenSource?) {
        self.provider = provider
        self.store = store
        _source = State(initialValue: source)
        // Only Azure has saved org/project; reading them for other providers would hit the Keychain on every render.
        let azure = provider == .azure ? AzureTarget.current : nil
        _org = State(initialValue: azure?.org ?? "")
        _project = State(initialValue: azure?.project ?? "")
    }

    private var azureMissing: Bool {
        provider == .azure && (org.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var showForm: Bool { source == nil || editing }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderMark(provider: provider)
                Text(provider.displayName).font(.headline)
                Spacer()
                if let source {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(source.label).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not connected").font(.caption).foregroundStyle(.tertiary)
                }
            }

            if source == .keychain, !editing {
                HStack {
                    Spacer()
                    Button("Remove", action: remove).controlSize(.small)
                    Button("Replace…") { editing = true }.controlSize(.small)
                }
            }

            if showForm {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(provider.setup.steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(step)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button {
                        NSWorkspace.shared.open(provider.setup.tokenURL)
                    } label: {
                        Label("Open \(provider.displayName) token page", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.link)
                    if provider == .azure {
                        HStack {
                            TextField("Organization (e.g. acme)", text: $org)
                                .textFieldStyle(.roundedBorder)
                            TextField("Project", text: $project)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    HStack {
                        SecureField(provider.setup.placeholder, text: $token)
                            .textFieldStyle(.roundedBorder)
                        Button("Paste") {
                            token = NSPasteboard.general.string(forType: .string)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        Button("Connect", action: connect)
                            .buttonStyle(.borderedProminent)
                            .disabled(token.isEmpty || checking || azureMissing)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    if let error {
                        Text("Couldn't connect: \(error)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .cardStyle(Color.primary.opacity(0.04))
    }

    private func connect() {
        error = nil
        if provider == .azure, !AzureTarget.save(org: org, project: project) {
            error = "enter your organization and project"
            return
        }
        checking = true
        Task {
            if let err = await provider.check(token: token) {
                error = err
            } else {
                provider.saveToken(token)
                token = ""
                source = provider.tokenSource
                editing = false
                await store.refresh()
            }
            checking = false
        }
    }

    private func remove() {
        provider.removeToken()
        source = provider.tokenSource
        Task { await store.refresh() }
    }
}

private extension View {
    func cardStyle(_ fill: Color) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}
