import Foundation

/// Fake deploys for `--snapshot <dir> --demo`, so menu designs can be compared without real accounts.
enum Demo {
    static func deploys(now: Date = Date()) -> [Deploy] {
        func make(_ n: Int, _ provider: Provider, _ project: String, repo: String, branch: String, commit: String,
                  message: String, state: DeployState, ago: TimeInterval, took: TimeInterval?, prod: Bool) -> Deploy {
            let createdAt = now.addingTimeInterval(-ago)
            return Deploy(id: "demo-\(project)-\(n)", provider: provider, project: project, repo: repo,
                          branch: branch, commit: commit, message: message, state: state, createdAt: createdAt,
                          finishedAt: took.map { createdAt.addingTimeInterval($0) },
                          url: URL(string: provider == .vercel ? "https://vercel.com/" : "https://dash.cloudflare.com/"),
                          isProduction: prod)
        }
        let v = Provider.vercel, c = Provider.cloudflare
        return [
            make(1, v, "storefront-web", repo: "storefront", branch: "main", commit: "a41c9e2", message: "Fix cart total rounding on mobile", state: .ready, ago: 240, took: 48, prod: true),
            make(2, v, "storefront-web", repo: "storefront", branch: "main", commit: "9be03d1", message: "Show stock levels on product cards", state: .ready, ago: 3600, took: 51, prod: true),
            make(3, v, "storefront-web", repo: "storefront", branch: "main", commit: "7c2aa40", message: "Show stock levels on product cards", state: .failed, ago: 5400, took: 12, prod: true),
            make(4, v, "storefront-web", repo: "storefront", branch: "main", commit: "1f0d8b3", message: "Add Apple Pay to checkout", state: .ready, ago: 20000, took: 47, prod: true),
            make(5, v, "storefront-web", repo: "storefront", branch: "main", commit: "e6b2a17", message: "Lazy-load review photos", state: .ready, ago: 90000, took: 55, prod: true),
            make(6, v, "storefront-web", repo: "storefront", branch: "main", commit: "30c9f54", message: "Tune image sizes", state: .ready, ago: 180000, took: 49, prod: true),

            make(1, c, "storefront-api", repo: "storefront", branch: "main", commit: "5d17be0", message: "Cache product lookups at the edge", state: .ready, ago: 720, took: 21, prod: true),
            make(2, c, "storefront-api", repo: "storefront", branch: "main", commit: "b28e6c3", message: "Rate-limit the search endpoint", state: .ready, ago: 30000, took: 19, prod: true),
            make(3, c, "storefront-api", repo: "storefront", branch: "main", commit: "0a9f4d1", message: "Bump wrangler to 4.12", state: .ready, ago: 100000, took: 24, prod: true),

            make(1, v, "dashboard", repo: "dashboard", branch: "feat/billing-page", commit: "c3e81f7", message: "Add billing page skeleton", state: .building, ago: 38, took: nil, prod: false),
            make(2, v, "dashboard", repo: "dashboard", branch: "feat/billing-page", commit: "8d24a5b", message: "Table filters keep their state", state: .ready, ago: 4000, took: 62, prod: false),
            make(3, v, "dashboard", repo: "dashboard", branch: "feat/billing-page", commit: "2b7f0c9", message: "Dark mode for charts", state: .ready, ago: 9000, took: 58, prod: false),
            make(4, v, "dashboard", repo: "dashboard", branch: "feat/billing-page", commit: "f1a63e8", message: "Export invoices as CSV", state: .ready, ago: 40000, took: 71, prod: false),
            make(5, v, "dashboard", repo: "dashboard", branch: "feat/billing-page", commit: "64de0b2", message: "Sidebar keyboard shortcuts", state: .ready, ago: 120000, took: 66, prod: false),

            make(1, c, "status", repo: "status-page", branch: "main", commit: "9f3b2c1", message: "Rewrite incident timeline", state: .failed, ago: 1560, took: 14, prod: true),
            make(2, c, "status", repo: "status-page", branch: "main", commit: "7e0a1d5", message: "Add RSS feed for incidents", state: .ready, ago: 50000, took: 33, prod: true),
            make(3, c, "status", repo: "status-page", branch: "main", commit: "d4c88b6", message: "Uptime bars use local time", state: .ready, ago: 150000, took: 31, prod: true),

            make(1, c, "docs", repo: "docs", branch: "main", commit: "2ac5f90", message: "Document webhook retries", state: .ready, ago: 7200, took: 92, prod: true),
            make(2, c, "docs", repo: "docs", branch: "main", commit: "51be7d3", message: "Add API rate limit table", state: .ready, ago: 86400, took: 88, prod: true),
        ]
    }
}
