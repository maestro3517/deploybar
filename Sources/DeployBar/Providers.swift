import Foundation
import Security

enum Provider: String, CaseIterable {
    case cloudflare, vercel, azure

    var displayName: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .vercel: return "Vercel"
        case .azure: return "Azure DevOps"
        }
    }

    /// How a new user gets a token. Drives the setup window.
    var setup: ProviderSetup {
        switch self {
        case .cloudflare:
            let perms = #"[{"key":"workers_scripts","type":"read"},{"key":"page","type":"read"},{"key":"workers_ci","type":"read"},{"key":"workers_builds_configuration","type":"read"}]"#
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
            return ProviderSetup(
                tokenURL: URL(string: "https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=\(perms)&accountId=%2A&zoneId=all&name=DeployBar")!,
                steps: ["Open the token page (My Profile › API Tokens, not Account API Tokens: only these can read builds). It is pre-filled with read-only access: Workers Scripts, Pages, Workers CI and Workers Builds Configuration.",
                        "Check that Workers CI shows Read ticked (it is marked Legacy, which is fine). If it is missing, search \"Workers CI\" and tick Read: it gives commit messages and build progress.",
                        "Click Continue to summary, then Create Token, and copy it."],
                placeholder: "Cloudflare API token")
        case .vercel:
            return ProviderSetup(
                tokenURL: URL(string: "https://vercel.com/account/settings/tokens")!,
                steps: ["Open Vercel › Account Settings › Tokens.",
                        "Create a token named DeployBar. Pick the team you deploy from (or Full Account).",
                        "Copy the token."],
                placeholder: "Vercel token")
        case .azure:
            return ProviderSetup(
                tokenURL: URL(string: "https://dev.azure.com/")!,
                steps: ["Open Azure DevOps, then User settings (top right) › Personal access tokens › New Token.",
                        "Name it DeployBar, pick your organization, choose Custom defined and tick Build › Read. Nothing else is needed.",
                        "Create it, copy the token, and fill in your organization and project below."],
                placeholder: "Azure DevOps personal access token")
        }
    }

    private var keychainAccount: String {
        switch self {
        case .cloudflare: return "cloudflare-token"
        case .vercel: return "vercel-token"
        case .azure: return "azure-token"
        }
    }

    /// Where the token in use comes from; nil = not connected.
    var tokenSource: TokenSource? {
        switch self {
        case .cloudflare:
            if env("CLOUDFLARE_API_TOKEN") != nil { return .environment("CLOUDFLARE_API_TOKEN") }
            return keychainValue(keychainAccount) != nil ? .keychain : nil
        case .vercel:
            if env("VERCEL_TOKEN") != nil { return .environment("VERCEL_TOKEN") }
            if keychainValue(keychainAccount) != nil { return .keychain }
            return vercelCLIToken() != nil ? .vercelCLI : nil
        case .azure:
            guard AzureTarget.current != nil else { return nil }
            if env("AZURE_DEVOPS_EXT_PAT") != nil { return .environment("AZURE_DEVOPS_EXT_PAT") }
            return keychainValue(keychainAccount) != nil ? .keychain : nil
        }
    }

    var token: String? {
        switch tokenSource {
        case .environment(let key): return env(key)
        case .keychain: return keychainValue(keychainAccount)
        case .vercelCLI: return vercelCLIToken()
        case nil: return nil
        }
    }

    /// Saves to the Keychain (service "deploybar"), trimmed. Returns false on failure.
    @discardableResult func saveToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && keychainSave(keychainAccount, t)
    }

    /// Deletes only the Keychain item. Env vars and the Vercel CLI login are untouched.
    func removeToken() {
        keychainDelete(keychainAccount)
        if self == .azure { AzureTarget.remove() }
    }

    /// One cheap API call. nil = token works, else a short human-readable error.
    func check(token: String) async -> String? {
        do {
            switch self {
            case .cloudflare: _ = try await getJSON("\(cfBase)/accounts?per_page=1", token)  // not cloudflareAccount(): it skips the API when an account id is saved
            case .vercel: _ = try await getJSON("https://api.vercel.com/v2/user", token)
            case .azure:
                guard let t = AzureTarget.current else { return "add your organization and project first" }
                do {
                    let json = try await getJSON(azureBuildsURL(t.org, t.project, top: 1), token, basic: true)
                    return json["value"] is [Any] ? nil : azureNotAccepted
                } catch let e as ProviderError where e.message == "HTTP 404" {
                    return "project not found in that organization"
                }
            }
            return nil
        } catch {
            return (error as? ProviderError)?.message ?? error.localizedDescription
        }
    }
}

struct ProviderSetup { let tokenURL: URL; let steps: [String]; let placeholder: String }

enum TokenSource: Equatable {
    case keychain, environment(String), vercelCLI
    var label: String {
        switch self {
        case .keychain: return "Saved in Keychain"
        case .environment(let key): return "From $\(key)"
        case .vercelCLI: return "From your Vercel CLI login"
        }
    }
}

enum DeployState: String { case queued, building, ready, failed, canceled, skipped }

struct Deploy: Identifiable, Hashable {
    let id: String
    let provider: Provider
    let project: String        // Worker / Pages project / Vercel project name
    let repo: String           // GitHub repo name, falls back to project
    let branch: String?
    let commit: String?        // 7 chars
    let message: String?       // first line, max 72 chars
    let state: DeployState
    let createdAt: Date
    var finishedAt: Date? = nil  // when the build stopped, if the API says
    let url: URL?              // dashboard/inspector link to open on click
    var logURL: URL? = nil     // API endpoint for this deploy's build log, if the platform has one
    let isProduction: Bool
    // A build stuck for 2 h is treated as dead so the menu bar stops spinning.
    var isActive: Bool { (state == .queued || state == .building) && createdAt > Date(timeIntervalSinceNow: -7200) }
}

enum AzureTarget {
    /// Saved organization and project, or nil when either is missing. Env AZURE_DEVOPS_ORG / AZURE_DEVOPS_PROJECT win over Keychain.
    static var current: (org: String, project: String)? {
        guard let org = env("AZURE_DEVOPS_ORG") ?? keychainValue("azure-org"),
              let project = env("AZURE_DEVOPS_PROJECT") ?? keychainValue("azure-project") else { return nil }
        return (org, project)
    }

    /// Saves both to the Keychain after normalizing. Returns false if either is empty after trimming or the save fails.
    @discardableResult static func save(org: String, project: String) -> Bool {
        let o = azureOrgName(org), p = project.trimmingCharacters(in: .whitespacesAndNewlines)
        return !o.isEmpty && !p.isEmpty && keychainSave("azure-org", o) && keychainSave("azure-project", p)
    }

    /// Deletes both Keychain items.
    static func remove() {
        keychainDelete("azure-org")
        keychainDelete("azure-project")
    }
}

/// "https://dev.azure.com/acme/", "acme.visualstudio.com", " acme " -> "acme".
func azureOrgName(_ input: String) -> String {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = s.range(of: #"^https?://"#, options: .regularExpression) { s.removeSubrange(r) }
    if s.hasPrefix("dev.azure.com/") { s.removeFirst("dev.azure.com/".count) }
    let first = String(s.prefix { $0 != "/" })
    let suffix = ".visualstudio.com"
    return first.hasSuffix(suffix) ? String(first.dropLast(suffix.count)) : first
}

enum Providers {
    static var anyConnected: Bool { Provider.allCases.contains { $0.tokenSource != nil } }

    /// Fetches every connected provider concurrently. Never throws: a provider that fails adds one human-readable line to `errors`; one with no token is skipped silently.
    static func fetchAll() async -> (deploys: [Deploy], errors: [String]) {
        await withTaskGroup(of: ([Deploy], [String]).self) { group in
            for (p, token) in Provider.allCases.compactMap({ p in p.token.map { (p, $0) } }) {
                group.addTask { await fetch(p, token: token) }
            }
            return await group.reduce(into: ([Deploy](), [String]())) { $0.0 += $1.0; $0.1 += $1.1 }
        }
    }

    private static func fetch(_ p: Provider, token: String) async -> ([Deploy], [String]) {
        switch p {
        case .cloudflare: return await fetchCloudflare(token)
        case .vercel: return await fetchVercel(token)
        case .azure: return await fetchAzure(token)
        }
    }
}

enum SelfTest {
    /// Parses embedded fixtures through the mappers, prints PASS/FAIL per test, returns all-passed.
    static func run() -> Bool {
        let tests: [(String, () -> String?)] = [
            ("vercel mapping", vercelMapping),
            ("cloudflare builds states", cloudflareBuildStates),
            ("cloudflare builds date and repo fallback", cloudflareBuildDate),
            ("pages mapping and skip", pagesMapping),
            ("notification transitions", notificationTransitions),
            ("start alerts", startAlerts),
            ("provider setup", providerSetup),
            ("build log parsing", buildLogParsing),
            ("cloudflare auth errors", { isAuthError("Invalid token") && isAuthError("Authentication error") && !isAuthError("HTTP 500") ? nil : "isAuthError misclassifies" }),
            ("azure mapping", azureMapping),
            ("azure org names", azureOrgNames),
        ]
        var allPassed = true
        for (name, test) in tests {
            if let why = test() {
                print("FAIL \(name): \(why)")
                allPassed = false
            } else {
                print("PASS \(name)")
            }
        }
        return allPassed
    }

    private static func providerSetup() -> String? {
        for p in Provider.allCases {
            if p.setup.steps.isEmpty { return "\(p.rawValue) has no steps" }
            if p.setup.tokenURL.scheme != "https" { return "\(p.rawValue) token URL is not https" }
        }
        let cf = Provider.cloudflare.setup.tokenURL.absoluteString
        for want in ["permissionGroupKeys=", "name=DeployBar", "%22workers_scripts%22", "%22workers_ci%22", "%22workers_builds_configuration%22"] where !cf.contains(want) {
            return "cloudflare URL lacks \(want)"
        }
        return nil
    }

    private static func notificationTransitions() -> String? {
        let since = Date()
        func dep(_ id: String, _ state: DeployState, _ created: Date) -> Deploy {
            Deploy(id: id, provider: .vercel, project: "p", repo: "p", branch: nil, commit: nil, message: nil,
                   state: state, createdAt: created, url: nil, isProduction: false)
        }
        let after = since.addingTimeInterval(10), before = since.addingTimeInterval(-10)
        func hits(_ prev: DeployState?, _ now: DeployState, firstLoad: Bool = false, created: Date = Date(),
                  notified: Set<String> = []) -> Bool {
            !finishedTransitions(previous: prev.map { ["x": $0] } ?? [:], fresh: [dep("x", now, created)],
                                 firstLoad: firstLoad, since: since, alreadyNotified: notified).isEmpty
        }
        if !hits(.building, .ready) { return "building->ready should notify" }
        if !hits(.queued, .failed) { return "queued->failed should notify" }
        if hits(.ready, .ready) { return "ready->ready should not notify" }
        if hits(.building, .canceled) { return "building->canceled should not notify" }
        if hits(.building, .building) { return "building->building should not notify" }
        if hits(nil, .ready, firstLoad: true, created: after) { return "unseen on first load should not notify" }
        if !hits(nil, .ready, created: after) { return "unseen new deploy should notify" }
        if hits(nil, .ready, created: before) { return "unseen old deploy should not notify" }
        if hits(.building, .ready, notified: ["x"]) { return "already notified should not notify" }
        return nil
    }

    private static func startAlerts() -> String? {
        func alerts(_ prev: DeployState?, _ now: DeployState, firstLoad: Bool = false, age: TimeInterval = 0) -> Bool {
            let d = Deploy(id: "x", provider: .vercel, project: "p", repo: "p", branch: nil, commit: nil, message: nil,
                           state: now, createdAt: Date(timeIntervalSinceNow: -age), url: nil, isProduction: false)
            return !startedDeploys(previous: prev.map { ["x": $0] } ?? [:], fresh: [d], firstLoad: firstLoad).isEmpty
        }
        if !alerts(nil, .building) { return "new building deploy should alert" }
        if !alerts(nil, .queued) { return "new queued deploy should alert" }
        if alerts(nil, .building, firstLoad: true) { return "first load should not alert" }
        if alerts(.queued, .building) { return "queued->building should not alert" }
        if alerts(nil, .ready) { return "new ready deploy should not alert" }
        if alerts(nil, .building, age: 3 * 3600) { return "3 h old building deploy should not alert" }
        return nil
    }

    private static func buildLogParsing() -> String? {
        let vercel = #"""
        [{"type":"stdout","text":"ok"},{"type":"stderr","text":"\u001b[31mError: boom\u001b[39m"},{"type":"delimiter","text":"x"}]
        """#
        guard let events = try? JSONSerialization.jsonObject(with: Data(vercel.utf8)) else { return "vercel fixture unparseable" }
        let v = logLines(events)
        if v.count != 2 || v[1] != "Error: boom" { return "vercel parse gave \(v)" }
        if logLines(parseJSON(#"{"result":{"lines":[[1,"a"],[2,"b"]]}}"#)) != ["a", "b"] { return "cloudflare builds parse wrong" }
        if logLines(parseJSON(#"{"result":{"data":[{"ts":"x","line":"c"}]}}"#)) != ["c"] { return "pages parse wrong" }
        let dep = Deploy(id: "x", provider: .cloudflare, project: "p", repo: "p", branch: "main", commit: "abc1234", message: "m",
                         state: .failed, createdAt: Date(), url: nil, isProduction: false)
        let p = agentPrompt(dep, log: ["FIRST"] + (2...200).map { "line \($0)" })
        if !p.contains("last 150 lines") || !p.contains("Find the cause of this build failure and fix it.") || p.contains("FIRST") {
            return "agentPrompt wrong"
        }
        if vercelDeploys(parseJSON(vercelFixture), scope: "&teamId=t1").first?.logURL?.absoluteString.hasSuffix("&teamId=t1") != true {
            return "vercel logURL missing scope"
        }
        if byID(pagesDeploys(account: "acct1", parseJSON(pagesFixture)))["p1"]?.logURL?.absoluteString
            != "https://api.cloudflare.com/client/v4/accounts/acct1/pages/projects/site-a/deployments/p1/history/logs" {
            return "pages logURL wrong"
        }
        return nil
    }

    private static func vercelMapping() -> String? {
        let d = byID(vercelDeploys(parseJSON(vercelFixture)))
        let want: [String: DeployState] = ["v1": .ready, "v2": .failed, "v3": .canceled, "v4": .building,
                                           "v5": .queued, "v6": .queued, "v7": .queued, "v8": .ready]
        for (id, state) in want where d[id]?.state != state {
            return "\(id) state is \(d[id]?.state.rawValue ?? "missing"), want \(state.rawValue)"
        }
        guard let v1 = d["v1"], let v2 = d["v2"], let v8 = d["v8"] else { return "v1, v2 or v8 missing" }
        if !v1.isProduction || v2.isProduction { return "production flag wrong" }
        if v1.repo != "web-repo" { return "v1 repo is \(v1.repo)" }
        if v8.repo != "solo" { return "v8 repo fallback is \(v8.repo)" }
        if v1.commit != "abcdef1" || v1.branch != "main" || v1.message != "fix: thing" { return "v1 commit/branch/message wrong" }
        if v1.url?.absoluteString != "https://vercel.com/x/v1" { return "v1 url wrong" }
        if abs(v1.createdAt.timeIntervalSince1970 - 1791540930.123) > 0.001 { return "v1 createdAt wrong" }
        return nil
    }

    private static func cloudflareBuildStates() -> String? {
        let d = byID(cloudflareBuilds(worker: "web-worker", account: "acct1", parseJSON(cfBuildFixture)))
        let want: [String: DeployState] = ["b1": .queued, "b2": .building, "b3": .building, "b4": .ready,
                                           "b5": .canceled, "b6": .canceled, "b7": .failed, "b8": .failed, "b9": .ready]
        for (id, state) in want where d[id]?.state != state {
            return "\(id) state is \(d[id]?.state.rawValue ?? "missing"), want \(state.rawValue)"
        }
        if d["b1"]?.isProduction != true { return "b1 not production" }
        if d["b1"]?.url?.absoluteString != "https://dash.cloudflare.com/acct1/workers/services/view/web-worker/production/builds/b1" {
            return "b1 url wrong"
        }
        return nil
    }

    private static func cloudflareBuildDate() -> String? {
        guard let b9 = byID(cloudflareBuilds(worker: "web-worker", account: "acct1", parseJSON(cfBuildFixture)))["b9"] else {
            return "b9 missing"
        }
        if abs(b9.createdAt.timeIntervalSince1970 - 1791540930.123) > 0.001 { return "fractional-seconds date not parsed" }
        if b9.repo != "web-worker" { return "repo fallback is \(b9.repo)" }
        if b9.branch != "main" || b9.commit != "1234567" || b9.message != "feat: x" { return "branch/commit/message wrong" }
        return nil
    }

    private static func pagesMapping() -> String? {
        let ds = pagesDeploys(account: "acct1", parseJSON(pagesFixture))
        let d = byID(ds)
        if ds.count != 7 || d["p7"] != nil { return "expected 7 deploys and no p7, got \(ds.count)" }
        let want: [String: DeployState] = ["p1": .ready, "p2": .building, "p3": .failed, "p4": .canceled,
                                           "p5": .building, "p6": .queued, "p8": .skipped]
        for (id, state) in want where d[id]?.state != state {
            return "\(id) state is \(d[id]?.state.rawValue ?? "missing"), want \(state.rawValue)"
        }
        if d["p1"]?.repo != "site-repo" || d["p3"]?.repo != "site-c" { return "repo fallback wrong" }
        if d["p1"]?.isProduction != true || d["p3"]?.isProduction != false { return "production flag wrong" }
        if d["p1"]?.commit != "abcdef0" || d["p1"]?.message != "ship it" { return "commit/message wrong" }
        if d["p1"]?.url?.absoluteString != "https://dash.cloudflare.com/acct1/pages/view/site-a/p1" { return "url wrong" }
        return nil
    }

    private static func azureMapping() -> String? {
        let ds = azureBuilds(org: "acme", project: "p", parseJSON(azureFixture))
        let d = byID(ds)
        let want: [String: DeployState] = ["1": .building, "2": .queued, "3": .ready, "4": .ready,
                                           "5": .failed, "6": .canceled, "7": .ready]
        if ds.count != 7 || d["ado-acme-8"] != nil { return "expected 7 builds and no build 8, got \(ds.count)" }
        for (id, state) in want where d["ado-acme-\(id)"]?.state != state {
            return "\(id) state is \(d["ado-acme-\(id)"]?.state.rawValue ?? "missing"), want \(state.rawValue)"
        }
        guard let b1 = d["ado-acme-1"], let pr = d["ado-acme-7"] else { return "build 1 or 7 missing" }
        if b1.project != "web-ci" || b1.repo != "web-repo" || b1.branch != "main" { return "build 1 project/repo/branch wrong" }
        if b1.commit != "abcdef1" || b1.message != "feat: x" { return "build 1 commit/message wrong" }
        if b1.url?.absoluteString != "https://dev.azure.com/acme/p/_build/results?buildId=1" { return "build 1 url wrong" }
        if !b1.isProduction || pr.isProduction { return "production flag wrong" }
        if abs(b1.createdAt.timeIntervalSince1970 - 1791540930.123) > 0.001 { return "7-digit fractional date not parsed" }
        if pr.branch != "PR 7" || pr.commit?.count != 7 || pr.message != "pr title" { return "PR build branch/commit/message wrong" }
        return nil
    }

    private static func azureOrgNames() -> String? {
        for (input, want) in [("https://dev.azure.com/acme/", "acme"), ("acme.visualstudio.com", "acme"),
                              (" acme ", "acme"), ("dev.azure.com/acme/proj", "acme")] where azureOrgName(input) != want {
            return "azureOrgName(\(input)) is \(azureOrgName(input)), want \(want)"
        }
        return nil
    }

    private static let azureFixture = #"""
    {"count":8,"value":[
     {"id":1,"status":"inProgress","result":null,"sourceBranch":"refs/heads/main","sourceVersion":"abcdef1234567","queueTime":"2026-10-09T10:15:30.1234567Z","definition":{"name":"web-ci"},"repository":{"name":"web-repo"},"triggerInfo":{"ci.message":"feat: x\n\nbody"},"reason":"individualCI","_links":{"web":{"href":"https://dev.azure.com/acme/p/_build/results?buildId=1"}}},
     {"id":2,"status":"notStarted","result":null,"sourceBranch":"refs/heads/main","sourceVersion":"abcdef1234567","queueTime":"2026-10-09T10:15:30Z","definition":{"name":"web-ci"},"repository":{"name":"web-repo"},"triggerInfo":{"ci.message":"feat: x"},"reason":"individualCI"},
     {"id":3,"status":"completed","result":"succeeded","sourceBranch":"refs/heads/main","sourceVersion":"abcdef1234567","queueTime":"2026-10-09T10:15:30Z","definition":{"name":"web-ci"},"repository":{"name":"web-repo"},"triggerInfo":{"ci.message":"feat: x"},"reason":"individualCI"},
     {"id":4,"status":"completed","result":"partiallySucceeded","sourceBranch":"refs/heads/main","sourceVersion":"abcdef1234567","queueTime":"2026-10-09T10:15:30Z","definition":{"name":"web-ci"},"repository":{"name":"web-repo"},"triggerInfo":{"ci.message":"feat: x"},"reason":"individualCI"},
     {"id":5,"status":"completed","result":"failed","sourceBranch":"refs/heads/main","sourceVersion":"abcdef1234567","queueTime":"2026-10-09T10:15:30Z","definition":{"name":"web-ci"},"repository":{"name":"web-repo"},"triggerInfo":{"ci.message":"feat: x"},"reason":"individualCI"},
     {"id":6,"status":"completed","result":"canceled","sourceBranch":"refs/heads/main","sourceVersion":"abcdef1234567","queueTime":"2026-10-09T10:15:30Z","definition":{"name":"web-ci"},"repository":{"name":"web-repo"},"triggerInfo":{"ci.message":"feat: x"},"reason":"individualCI"},
     {"id":7,"status":"completed","result":"succeeded","sourceBranch":"refs/pull/7/merge","sourceVersion":"1111111aaaa","queueTime":"2026-10-09T10:15:30Z","definition":{"name":"web-ci"},"repository":{"name":"web-repo"},"triggerInfo":{"pr.title":"pr title"},"reason":"pullRequest"},
     {"id":8,"status":"completed","result":"succeeded","sourceBranch":"refs/heads/main","sourceVersion":"abcdef1234567","queueTime":"2026-10-09T10:15:30Z","repository":{"name":"web-repo"},"reason":"individualCI"}
    ]}
    """#

    private static let vercelFixture = #"""
    {"deployments":[
     {"uid":"v1","name":"web","state":"READY","target":"production","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v1","meta":{"githubCommitRef":"main","githubCommitSha":"abcdef1234567","githubCommitMessage":"fix: thing\n\nlong body","githubRepo":"web-repo"}},
     {"uid":"v2","name":"web","state":"ERROR","target":"preview","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v2","meta":{}},
     {"uid":"v3","name":"web","state":"CANCELED","target":"preview","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v3","meta":{}},
     {"uid":"v4","name":"web","state":"BUILDING","target":"preview","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v4","meta":{}},
     {"uid":"v5","name":"web","state":"INITIALIZING","target":"preview","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v5","meta":{}},
     {"uid":"v6","name":"web","state":"QUEUED","target":"preview","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v6","meta":{}},
     {"uid":"v7","name":"web","state":"WEIRD","target":"preview","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v7","meta":{}},
     {"uid":"v8","name":"solo","state":"READY","target":"production","created":1791540930123,"inspectorUrl":"https://vercel.com/x/v8","meta":{}}
    ]}
    """#

    private static let cfBuildFixture = #"""
    {"success":true,"result":[
     {"build_uuid":"b1","status":"queued","build_outcome":null,"created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b2","status":"running","build_outcome":null,"created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b3","status":"initializing","build_outcome":null,"created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b4","status":"stopped","build_outcome":"success","created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b5","status":"stopped","build_outcome":"canceled","created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b6","status":"stopped","build_outcome":"cancelled","created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b7","status":"stopped","build_outcome":"fail","created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b8","status":"stopped","build_outcome":"failure","created_on":"2026-10-09T10:15:30Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x","repo_name":"web-repo"}},
     {"build_uuid":"b9","status":"stopped","build_outcome":"success","created_on":"2026-10-09T10:15:30.123Z","build_trigger_metadata":{"branch":"main","commit_hash":"1234567890","commit_message":"feat: x"}}
    ]}
    """#

    private static let pagesFixture = #"""
    {"success":true,"result":[
     {"name":"site-a","source":{"config":{"repo_name":"site-repo"}},"latest_deployment":{"id":"p1","created_on":"2026-10-09T10:15:30Z","environment":"production","deployment_trigger":{"metadata":{"branch":"main","commit_hash":"abcdef0123","commit_message":"ship it"}},"latest_stage":{"name":"deploy","status":"success"}}},
     {"name":"site-b","latest_deployment":{"id":"p2","created_on":"2026-10-09T10:15:30Z","environment":"preview","latest_stage":{"name":"build","status":"success"}}},
     {"name":"site-c","latest_deployment":{"id":"p3","created_on":"2026-10-09T10:15:30Z","environment":"preview","latest_stage":{"name":"deploy","status":"failure"}}},
     {"name":"site-d","latest_deployment":{"id":"p4","created_on":"2026-10-09T10:15:30Z","environment":"preview","latest_stage":{"name":"build","status":"canceled"}}},
     {"name":"site-e","latest_deployment":{"id":"p5","created_on":"2026-10-09T10:15:30Z","environment":"preview","latest_stage":{"name":"build","status":"active"}}},
     {"name":"site-f","latest_deployment":{"id":"p6","created_on":"2026-10-09T10:15:30Z","environment":"preview","latest_stage":{"name":"build","status":"queued"}}},
     {"name":"site-h","latest_deployment":{"id":"p8","created_on":"2026-10-09T10:15:30Z","environment":"preview","is_skipped":true,"latest_stage":{"name":"queued","status":"idle"}}},
     {"name":"site-g"}
    ]}
    """#
}

// MARK: - Mappers

func vercelDeploys(_ json: [String: Any], scope: String = "") -> [Deploy] {
    (json["deployments"] as? [[String: Any]] ?? []).compactMap { d -> Deploy? in
        guard let id = d["uid"] as? String, let name = d["name"] as? String else { return nil }
        let meta = d["meta"] as? [String: Any] ?? [:]
        return Deploy(
            id: id, provider: .vercel, project: name,
            repo: meta["githubRepo"] as? String ?? name,
            branch: meta["githubCommitRef"] as? String,
            commit: sha7(meta["githubCommitSha"] as? String),
            message: firstLine(meta["githubCommitMessage"] as? String),
            state: vercelState(d["state"] as? String ?? ""),
            createdAt: Date(timeIntervalSince1970: ((d["created"] as? Double) ?? 0) / 1000),
            finishedAt: (d["ready"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            url: (d["inspectorUrl"] as? String).flatMap(URL.init(string:)),
            logURL: URL(string: "https://api.vercel.com/v3/deployments/\(id)/events?builds=1&limit=-1\(scope)"),
            isProduction: (d["target"] as? String) == "production")
    }
}

func cloudflareBuilds(worker: String, account: String, _ json: [String: Any]) -> [Deploy] {
    (json["result"] as? [[String: Any]] ?? []).compactMap { b -> Deploy? in
        guard let uuid = b["build_uuid"] as? String else { return nil }
        let meta = b["build_trigger_metadata"] as? [String: Any]
        return Deploy(
            id: uuid, provider: .cloudflare, project: worker,
            repo: meta?["repo_name"] as? String ?? worker,
            branch: meta?["branch"] as? String,
            commit: sha7(meta?["commit_hash"] as? String),
            message: firstLine(meta?["commit_message"] as? String),
            state: cfBuildState(status: b["status"] as? String ?? "", outcome: b["build_outcome"] as? String),
            createdAt: parseISO((b["created_on"] as? String) ?? (b["created_at"] as? String)) ?? .distantPast,
            finishedAt: parseISO(b["stopped_on"] as? String),
            url: URL(string: "https://dash.cloudflare.com/\(account)/workers/services/view/\(worker)/production/builds/\(uuid)"),
            logURL: URL(string: "\(cfBase)/accounts/\(account)/builds/builds/\(uuid)/logs"),
            isProduction: true)
    }
}

func workerDeployments(worker: String, account: String, _ json: [String: Any]) -> [Deploy] {
    let list = (json["result"] as? [String: Any])?["deployments"] as? [[String: Any]] ?? []
    return list.prefix(3).compactMap { d -> Deploy? in
        guard let id = d["id"] as? String else { return nil }
        let notes = d["annotations"] as? [String: Any]
        return Deploy(
            id: id, provider: .cloudflare, project: worker, repo: worker,
            branch: nil, commit: nil,
            message: firstLine(notes?["workers/message"] as? String) ?? (d["source"] as? String).map { "Deployed with \($0 == "wrangler" ? "Wrangler" : $0)" },
            state: .ready,
            createdAt: parseISO(d["created_on"] as? String) ?? .distantPast,
            url: URL(string: "https://dash.cloudflare.com/\(account)/workers/services/view/\(worker)/production/deployments"),
            isProduction: true)
    }
}

func pagesDeploys(account: String, _ json: [String: Any]) -> [Deploy] {
    (json["result"] as? [[String: Any]] ?? []).compactMap { p -> Deploy? in
        guard let name = p["name"] as? String,
              let dep = p["latest_deployment"] as? [String: Any],
              let id = dep["id"] as? String else { return nil }
        let config = (p["source"] as? [String: Any])?["config"] as? [String: Any]
        let trigger = (dep["deployment_trigger"] as? [String: Any])?["metadata"] as? [String: Any]
        return Deploy(
            id: id, provider: .cloudflare, project: name,
            repo: config?["repo_name"] as? String ?? name,
            branch: trigger?["branch"] as? String,
            commit: sha7(trigger?["commit_hash"] as? String),
            message: firstLine(trigger?["commit_message"] as? String),
            // A skipped build (e.g. preview deploys turned off) keeps its "queued" stage forever.
            state: dep["is_skipped"] as? Bool == true ? .skipped : pagesState(dep["latest_stage"] as? [String: Any]),
            createdAt: parseISO(dep["created_on"] as? String) ?? .distantPast,
            finishedAt: (dep["latest_stage"] as? [String: Any]).flatMap { parseISO($0["ended_on"] as? String) },
            url: URL(string: "https://dash.cloudflare.com/\(account)/pages/view/\(name)/\(id)"),
            logURL: URL(string: "\(cfBase)/accounts/\(account)/pages/projects/\(name)/deployments/\(id)/history/logs"),
            isProduction: (dep["environment"] as? String) == "production")
    }
}

func azureBuilds(org: String, project: String, _ json: [String: Any]) -> [Deploy] {
    (json["value"] as? [[String: Any]] ?? []).compactMap { b -> Deploy? in
        guard let id = b["id"] as? Int, let defName = (b["definition"] as? [String: Any])?["name"] as? String else { return nil }
        let src = b["sourceBranch"] as? String
        let pr = src?.split(separator: "/").dropFirst(2).first  // refs/pull/123/merge
        let trigger = b["triggerInfo"] as? [String: Any]
        let web = (b["_links"] as? [String: Any])?["web"] as? [String: Any]
        return Deploy(
            id: "ado-\(org)-\(id)", provider: .azure, project: defName,
            repo: (b["repository"] as? [String: Any])?["name"] as? String ?? defName,
            branch: src.map { $0.hasPrefix("refs/pull/") ? "PR \(pr ?? "")" : $0.replacingOccurrences(of: "refs/heads/", with: "") },
            commit: sha7(b["sourceVersion"] as? String),
            message: firstLine((trigger?["ci.message"] ?? trigger?["pr.title"]) as? String),
            state: azureState(status: b["status"] as? String ?? "", result: b["result"] as? String),
            createdAt: parseISO(b["queueTime"] as? String) ?? .distantPast,
            finishedAt: parseISO(b["finishTime"] as? String),
            url: (web?["href"] as? String).flatMap(URL.init(string:)),
            isProduction: (b["reason"] as? String) != "pullRequest" && src?.hasPrefix("refs/pull/") != true)
    }
}

private func azureState(status: String, result: String?) -> DeployState {
    switch status {
    case "notStarted", "postponed", "none": return .queued
    case "inProgress", "cancelling": return .building
    default:
        switch result {
        case "succeeded", "partiallySucceeded": return .ready
        case "canceled": return .canceled
        default: return .failed
        }
    }
}

private func vercelState(_ s: String) -> DeployState {
    switch s {
    case "READY": return .ready
    case "ERROR": return .failed
    case "CANCELED": return .canceled
    case "BUILDING": return .building
    default: return .queued
    }
}

private func cfBuildState(status: String, outcome: String?) -> DeployState {
    switch status {
    case "queued": return .queued
    case "initializing", "running": return .building
    default:
        switch outcome {
        case "success": return .ready
        case "canceled", "cancelled": return .canceled
        default: return .failed
        }
    }
}

private func pagesState(_ stage: [String: Any]?) -> DeployState {
    let name = stage?["name"] as? String ?? ""
    switch stage?["status"] as? String ?? "" {
    case "failure": return .failed
    case "canceled": return .canceled
    case "success": return name == "deploy" ? .ready : .building
    case "active": return .building
    default: return .queued
    }
}

// MARK: - Build logs

/// Text lines from any of the three build-log response shapes, ANSI colour codes stripped.
func logLines(_ json: Any) -> [String] {
    var lines: [String] = []
    if let events = json as? [[String: Any]] {
        lines = events.compactMap { e -> String? in
            guard ["stdout", "stderr", "command"].contains(e["type"] as? String ?? "") else { return nil }
            return e["text"] as? String ?? (e["payload"] as? [String: Any])?["text"] as? String
        }
    } else if let result = (json as? [String: Any])?["result"] as? [String: Any] {
        if let pairs = result["lines"] as? [[Any]] {
            lines = pairs.compactMap { $0.count > 1 ? $0[1] as? String : nil }
        } else if let rows = result["data"] as? [[String: Any]] {
            lines = rows.compactMap { $0["line"] as? String }
        }
    }
    return lines.map {
        $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
          .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
}

/// Fetches a deploy's build log lines (ANSI colour codes stripped). Throws on network/API errors or when there is no log URL or token.
func fetchBuildLog(_ d: Deploy) async throws -> [String] {
    guard let url = d.logURL, let token = d.provider.token else {
        throw ProviderError(message: "No build log for this deploy")
    }
    return logLines(try await getAny(url.absoluteString, token))
}

/// Ready-to-paste text for an AI coding agent: what failed, where, and the last 150 log lines in a code fence.
func agentPrompt(_ d: Deploy, log: [String]) -> String {
    let tail = log.suffix(150)
    var s = "My \(d.provider.displayName) deploy of \"\(d.project)\" failed.\n"
    if let b = d.branch { s += "Branch: \(b)\n" }
    if let c = d.commit { s += "Commit: \(c)\(d.message.map { " \($0)" } ?? "")\n" }
    if let u = d.url { s += "Dashboard: \(u.absoluteString)\n" }
    s += "\nBuild log (last \(tail.count) lines):\n"
    s += tail.isEmpty ? "(no build log available)\n" : "```text\n\(tail.joined(separator: "\n"))\n```\n"
    return s + "\nFind the cause of this build failure and fix it."
}

// MARK: - Fetching

private struct ProviderError: Error { let message: String }

private let cfBase = "https://api.cloudflare.com/client/v4"

private func fetchVercel(_ token: String) async -> ([Deploy], [String]) {
    let teamIds: [String]
    do {
        let json = try await getJSON("https://api.vercel.com/v2/teams", token)
        teamIds = (json["teams"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    } catch {
        return ([], [errLine("Vercel", error)])
    }
    let scopes = teamIds.isEmpty ? [""] : teamIds.map { "&teamId=\($0)" }
    var deploys: [Deploy] = [], errors: [String] = []
    for scope in scopes {
        do {
            let json = try await getJSON("https://api.vercel.com/v6/deployments?limit=20\(scope)", token)
            deploys += vercelDeploys(json, scope: scope)
        } catch {
            errors.append(errLine("Vercel", error))
        }
    }
    return (deploys, errors)
}

private let azureNotAccepted = "token not accepted (check it has Build › Read and the organization is right)"

private func azureBuildsURL(_ org: String, _ project: String, top: Int) -> String {
    let p = project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project
    return "https://dev.azure.com/\(org)/\(p)/_apis/build/builds?api-version=7.1&queryOrder=queueTimeDescending&$top=\(top)"
}

private func fetchAzure(_ token: String) async -> ([Deploy], [String]) {
    guard let t = AzureTarget.current else { return ([], []) }
    do {
        let json = try await getJSON(azureBuildsURL(t.org, t.project, top: 50), token, basic: true)
        return (azureBuilds(org: t.org, project: t.project, json), [])
    } catch {
        return ([], [errLine("Azure DevOps", error)])
    }
}

private func fetchCloudflare(_ token: String) async -> ([Deploy], [String]) {
    let acct: String
    do {
        acct = try await cloudflareAccount(token)
    } catch {
        return ([], [errLine("Cloudflare", error)])
    }
    var deploys: [Deploy] = [], errors: [String] = []
    do {
        let (ds, buildsDenied) = try await workerBuilds(acct, token)
        deploys += ds
        if buildsDenied {
            // The Builds API only accepts user tokens; an account-owned token fails /user/tokens/verify.
            let userToken = (try? await getJSON("\(cfBase)/user/tokens/verify", token)) != nil
            errors.append(userToken
                ? "Cloudflare: to see commit messages, edit your token at My Profile › API Tokens and tick Workers CI › Read (marked Legacy, still works)."
                : "Cloudflare: commit messages need a token from My Profile › API Tokens. Account API Tokens can't read builds. Make one there with Workers CI › Read, then paste it in Accounts….")
        }
    } catch {
        errors.append(errLine("Cloudflare", error))
    }
    do {
        let json = try await getJSON("\(cfBase)/accounts/\(acct)/pages/projects", token)
        deploys += pagesDeploys(account: acct, json)
    } catch {
        errors.append(errLine("Cloudflare Pages", error))
    }
    return (deploys, errors)
}

/// Also reports whether the token was refused by the Workers Builds API (it lacks Workers CI Read, or is an account-owned token, which that API rejects),
/// in which case only the bare deploy history ("Deployed with Wrangler") is available.
private func workerBuilds(_ acct: String, _ token: String) async throws -> ([Deploy], denied: Bool) {
    let scripts = try await getJSON("\(cfBase)/accounts/\(acct)/workers/scripts", token)
    let workers: [(String, String)] = (scripts["result"] as? [[String: Any]] ?? []).prefix(25).compactMap { w -> (String, String)? in
        guard let name = w["id"] as? String, let tag = w["tag"] as? String else { return nil }
        return (name, tag)
    }
    return await withTaskGroup(of: ([Deploy], Bool).self) { group -> ([Deploy], denied: Bool) in
        for (name, tag) in workers {
            group.addTask {
                var denied = false
                var json: [String: Any] = [:]
                do {
                    json = try await getJSON("\(cfBase)/accounts/\(acct)/builds/workers/\(tag)/builds?per_page=5", token)
                } catch let e as ProviderError {
                    denied = isAuthError(e.message)
                } catch {}
                let builds = cloudflareBuilds(worker: name, account: acct, json)
                if !builds.isEmpty { return (builds, false) }
                // No Workers Builds (wrangler deploys, or a token without builds access): use the deploy history instead.
                let deps = (try? await getJSON("\(cfBase)/accounts/\(acct)/workers/scripts/\(name)/deployments", token)) ?? [:]
                return (workerDeployments(worker: name, account: acct, deps), denied)
            }
        }
        return await group.reduce(into: ([Deploy](), denied: false)) { $0.0 += $1.0; $0.denied = $0.denied || $1.1 }
    }
}

/// Cloudflare answers "Invalid token" (12006) or "Authentication error" (10000) when a token lacks a permission.
func isAuthError(_ message: String) -> Bool {
    let m = message.lowercased()
    return m.contains("invalid token") || m.contains("authentication error") || m.contains("not authorized")
}

private func cloudflareAccount(_ token: String) async throws -> String {
    if let id = env("CLOUDFLARE_ACCOUNT_ID") ?? keychainValue("cloudflare-account") { return id }
    let json = try await getJSON("\(cfBase)/accounts?per_page=50", token)
    guard let id = (json["result"] as? [[String: Any]])?.first?["id"] as? String else {
        throw ProviderError(message: "no account found")
    }
    return id
}

private func getAny(_ url: String, _ token: String, basic: Bool = false) async throws -> Any {
    guard let u = URL(string: url) else { throw ProviderError(message: "bad URL") }
    var req = URLRequest(url: u)
    req.timeoutInterval = 20
    req.setValue(basic ? "Basic \(Data(":\(token)".utf8).base64EncodedString())" : "Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let parsed = try? JSONSerialization.jsonObject(with: data)
    // Azure answers a bad PAT with HTTP 203 and an HTML sign-in page.
    if basic && parsed == nil { throw ProviderError(message: azureNotAccepted) }
    let any = parsed ?? [String: Any]()
    let json = any as? [String: Any] ?? [:]
    let cfErr = (json["errors"] as? [[String: Any]])?.first?["message"] as? String
    let vercelErr = (json["error"] as? [String: Any])?["message"] as? String
    let azureErr = json["typeKey"] != nil ? json["message"] as? String : nil
    if let m = cfErr ?? vercelErr ?? azureErr { throw ProviderError(message: m) }
    if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
        throw ProviderError(message: "HTTP \(code)")
    }
    if (json["success"] as? Bool) == false { throw ProviderError(message: "request failed") }
    return any
}

private func getJSON(_ url: String, _ token: String, basic: Bool = false) async throws -> [String: Any] {
    (try await getAny(url, token, basic: basic)) as? [String: Any] ?? [:]
}

// MARK: - Tokens

private func env(_ key: String) -> String? {
    let v = ProcessInfo.processInfo.environment[key]
    return v?.isEmpty == false ? v : nil
}

private func vercelCLIToken() -> String? {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.vercel.cli/auth.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = json["token"] as? String, !t.isEmpty else { return nil }
    return t
}

private func keychainValue(_ account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "deploybar",
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
          let data = out as? Data,
          let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty else { return nil }
    return s
}

private func keychainSave(_ account: String, _ value: String) -> Bool {
    let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "deploybar",
        kSecAttrAccount as String: account,
    ]
    let data = Data(value.utf8)
    let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
        return SecItemAdd(key.merging([kSecValueData as String: data]) { $1 } as CFDictionary, nil) == errSecSuccess
    }
    return status == errSecSuccess
}

private func keychainDelete(_ account: String) {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "deploybar",
        kSecAttrAccount as String: account,
    ] as CFDictionary)
}

// MARK: - Helpers

private func errLine(_ provider: String, _ error: Error) -> String {
    "\(provider): \((error as? ProviderError)?.message ?? error.localizedDescription)"
}

private func sha7(_ s: String?) -> String? {
    s.map { String($0.prefix(7)) }
}

private func firstLine(_ s: String?) -> String? {
    guard let line = s?.split(whereSeparator: \.isNewline).first, !line.isEmpty else { return nil }
    return String(line.prefix(72))
}

private func parseISO(_ s: String?) -> Date? {
    // Azure sends 7 fractional digits; the formatter takes 3.
    guard let s = s?.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression) else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

private func parseJSON(_ s: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
}

private func byID(_ ds: [Deploy]) -> [String: Deploy] {
    Dictionary(ds.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
}
