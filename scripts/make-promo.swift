import SwiftUI
import AppKit

// Usage: swift scripts/make-promo.swift <outDir> <framesDir>
// Renders marketing/post.png, marketing/social-preview.png and 450 reel frames (0000.png...) into <framesDir>.
// Run from the repo root; reads assets/icon.png, assets/screenshot-dark.png.
let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: make-promo.swift <outDir> <framesDir>\n".utf8)); exit(2) }
let outDir = args[1], framesDir = args[2]

extension Color {
    init(hex v: UInt32, _ a: Double = 1) {
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: a)
    }
}
let canvas = Color(hex: 0x0C0B1A), accent = Color(hex: 0x6366F1)
let green = Color(hex: 0x34C759), red = Color(hex: 0xFF453A)

// MARK: motion (cubic ease-out everywhere)
func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
func ease(_ t: Double) -> Double { let u = 1 - clamp(t); return 1 - u * u * u }
/// Eased progress of a move starting at frame `s`, lasting `d` frames.
func p(_ f: Int, _ s: Int, _ d: Int = 18) -> Double { ease(Double(f - s) / Double(d)) }

extension View {
    func arrive(_ pr: Double, _ mult: Double = 1, dy: CGFloat = 30) -> some View { opacity(pr * mult).offset(y: dy * (1 - pr)) }
    /// Pin the view's top-left corner at (x, y) inside a fixed-size ZStack.
    func at(_ x: CGFloat, _ y: CGFloat) -> some View {
        padding(.leading, x).padding(.top, y).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: building blocks
func H(_ s: String, _ size: CGFloat, _ op: Double = 1) -> some View {
    Text(s).font(.system(size: size, weight: .heavy)).tracking(-1.5).lineSpacing(-size * 0.06)
        .foregroundStyle(.white.opacity(op)).fixedSize(horizontal: false, vertical: true)
}
func body(_ s: String, _ size: CGFloat, _ op: Double = 0.62) -> some View {
    Text(s).font(.system(size: size, weight: .medium)).foregroundStyle(.white.opacity(op)).fixedSize(horizontal: false, vertical: true)
}

struct Icon: View {  // visible squircle is `size` px (the icon PNG has 100/1024 transparent padding)
    let img: NSImage; let size: CGFloat
    var body: some View {
        Image(nsImage: img).resizable().interpolation(.high)
            .frame(width: size * 1024 / 824, height: size * 1024 / 824)
            .frame(width: size, height: size).clipped()
    }
}

struct Shot: View {
    let img: NSImage; var w: CGFloat? = nil; var h: CGFloat? = nil
    var body: some View {
        Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
    }
}

struct Strip: View {
    let building: Bool; let angle: Double; var w: CGFloat = 1080; var h: CGFloat = 56
    var body: some View {
        let k = h / 56
        HStack(spacing: 0) {
            Image(systemName: "apple.logo").font(.system(size: 28 * k))
            Spacer()
            HStack(spacing: 30 * k) {
                Image(systemName: building ? "arrow.triangle.2.circlepath" : "checkmark.icloud").font(.system(size: 26 * k))
                    .rotationEffect(.degrees(building ? angle : 0)).frame(width: 36 * k)
                Image(systemName: "wifi").font(.system(size: 26 * k))
                Image(systemName: "battery.75").font(.system(size: 26 * k))
                Text("Mon 9:41").font(.system(size: 26 * k, weight: .medium))
            }
        }
        .foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 36)
        .frame(width: w, height: h).background(Color(hex: 0x1C1B2A))
    }
}

struct Banner: View {
    let icon: NSImage; let ok: Bool; let w: CGFloat
    var body: some View {
        let title = ok ? "storefront-web deployed on Vercel" : "status failed on Cloudflare"
        let hash = ok ? "a41c9e2" : "9f3b2c1"
        let msg = ok ? "Fix cart total rounding on mobile" : "Rewrite incident timeline"
        HStack(alignment: .top, spacing: 20) {
            Icon(img: icon, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                Text("Production · main").font(.system(size: 26)).foregroundStyle(.white.opacity(0.85))
                (Text(hash).font(.system(size: 26, design: .monospaced)) + Text(" · \(msg)").font(.system(size: 26)))
                    .foregroundStyle(.white.opacity(0.62))
            }
            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24).frame(width: w)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(hex: 0x2A2938)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Text("now").font(.system(size: 22)).foregroundStyle(.white.opacity(0.5)).padding(.top, 22).padding(.trailing, 26)
        }
        .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
    }
}

/// Promo copy of the app's dark "Deploy started" popover (StartAlert.swift), drawn `k` times larger.
/// Its arrow sits at the top centre, so pin it with the centre under the menu bar icon.
struct StartPop: View {
    let fraction: Double; let angle: Double; var k: CGFloat = 1.75
    var body: some View {
        let dim = Color.white.opacity(0.55)
        VStack(alignment: .leading, spacing: 8 * k) {
            HStack(spacing: 6 * k) {
                Image(systemName: "hammer.fill").font(.system(size: 12 * k)).foregroundStyle(.orange)
                Text("Deploy started").font(.system(size: 12 * k, weight: .semibold)).foregroundStyle(dim)
                Spacer()
                Image(systemName: "xmark.circle.fill").font(.system(size: 13 * k)).foregroundStyle(.white.opacity(0.35))
            }
            VStack(alignment: .leading, spacing: 3 * k) {
                HStack(spacing: 6 * k) {
                    Circle().trim(from: 0, to: 0.7).stroke(dim, style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round))
                        .frame(width: 9 * k, height: 9 * k).rotationEffect(.degrees(angle))
                    Text("dashboard").font(.system(size: 13 * k, weight: .semibold)).foregroundStyle(.white)
                    Image(systemName: "triangle.fill").font(.system(size: 8 * k, weight: .semibold)).foregroundStyle(.white)
                    Text("Preview").font(.system(size: 10 * k, weight: .medium)).foregroundStyle(dim)
                        .padding(.horizontal, 5 * k).padding(.vertical, 1 * k)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: k))
                }
                Text("Add billing page skeleton").font(.system(size: 12 * k)).foregroundStyle(dim)
                Text("feat/billing-page · c3e81f7").font(.system(size: 10 * k)).foregroundStyle(.white.opacity(0.3))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(.white).frame(width: 296 * k * fraction)
                }
                .frame(width: 296 * k, height: 5 * k).padding(.top, 2 * k)
                HStack(spacing: 6 * k) {
                    Text("\(Int(fraction * 100))%").font(.system(size: 10 * k, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                    Text("About \(Int(64 * (1 - fraction)))s left").font(.system(size: 10 * k)).foregroundStyle(dim)
                }
            }
        }
        .padding(12 * k).frame(width: 320 * k, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10 * k, style: .continuous).fill(Color(hex: 0x262626)))
        .overlay(RoundedRectangle(cornerRadius: 10 * k, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .top) {
            Path { p in p.move(to: CGPoint(x: 0, y: 9 * k)); p.addLine(to: CGPoint(x: 9 * k, y: 0)); p.addLine(to: CGPoint(x: 18 * k, y: 9 * k)) }
                .fill(Color(hex: 0x262626)).frame(width: 18 * k, height: 9 * k).offset(y: -9 * k + 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
    }
}

func dotHeadline(_ s: String, _ c: Color, size: CGFloat = 96, w: CGFloat = 900) -> some View {
    HStack(alignment: .top, spacing: 24) {
        Circle().fill(c).frame(width: 22, height: 22).padding(.top, size * 0.385)
        H(s, size)
    }.frame(width: w, alignment: .leading)
}

// MARK: reel
struct Assets { let icon: NSImage; let dark: NSImage }

/// `land` = 1920x1080 landscape layout (headlines left 45%, screenshot + banners right 55%); otherwise 1080x1920 portrait.
@MainActor func reel(_ f: Int, _ a: Assets, land: Bool = false) -> some View {
    let building = f >= 75 && f < 180
    let angle = building ? 360 * ease(Double((f - 75) % 30) / 22) : 0
    let old = 1 - p(f, 375, 10)                       // everything but the outro fades into scene 5
    let o1 = 1 - p(f, 75, 10), o2 = 1 - p(f, 180, 10), o3 = 1 - p(f, 285, 10)
    let sIn = p(f, 75, 22)
    let zoom = 1 + 0.03 * ease(Double(f - 75) / 300)
    let shotAlpha = sIn * (1 - 0.65 * p(f, 180, 10))
    let inS = p(f, 190, 22), outS = p(f, 285, 22), inF = p(f, 293, 22)
    let t0 = 381
    let W: CGFloat = land ? 1920 : 1080
    let sh: CGFloat = land ? 50 : 56                   // menu bar strip height
    let bannerX: CGFloat = land ? 864 + (1056 - 920) / 2 : 80
    let bannerY: CGFloat = sh + 80

    /// Landscape headlines: left column, vertically centred below the strip.
    func left<V: View>(_ v: V, w: CGFloat) -> some View {
        v.frame(width: w, alignment: .leading).padding(.leading, 90).padding(.top, sh)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    let shot = land
        ? AnyView(Shot(img: a.dark, h: 820).scaleEffect(zoom).offset(y: -60 * (1 - sIn)).opacity(shotAlpha)
            .frame(width: 1056, height: 1080 - sh).padding(.top, sh)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing))
        : AnyView(Shot(img: a.dark, w: 900).scaleEffect(zoom).offset(y: -60 * (1 - sIn)).opacity(shotAlpha)
            .frame(maxWidth: .infinity, maxHeight: .infinity))

    return ZStack(alignment: .topLeading) {
        canvas
        ZStack(alignment: .topLeading) {
            // scene 1
            VStack(alignment: .leading, spacing: 6) {
                H("You pushed.", 120).arrive(p(f, 6), o1)
                H("Is it live yet?", 120, 0.62).arrive(p(f, 33), o1)
            }
            .frame(width: 900, alignment: .leading).padding(.leading, 90)
            .padding(.top, land ? sh : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // scene 2
            let scene2 = VStack(alignment: .leading, spacing: 24) {
                H("Every deploy, one glance.", 84).arrive(p(f, 78), o2)
                H("It pops up the second a build starts.", 56, 0.62).arrive(p(f, 104), o2)
            }
            if land {
                left(scene2, w: 640)
            } else {
                scene2.frame(width: 900, alignment: .leading).at(90, 1460)
            }
            // screenshot, scenes 2-4
            shot
            // "Deploy started" popover drops out of the menu bar icon while it spins
            let popIn = p(f, 96, 14)
            StartPop(fraction: 0.12 + 0.7 * clamp(Double(f - 96) / 78), angle: Double(f) * 14)
                .scaleEffect(0.92 + 0.08 * popIn, anchor: .top).opacity(popIn * (1 - p(f, 174, 8)))
                .at(W - (land ? 302 : 334) - 280, sh + 22)
            // scene 3 / 4 headlines
            if land {
                left(dotHeadline("Know the second it's live.", green, size: 84, w: 760).arrive(p(f, 186), o3), w: 760)
                left(dotHeadline("Or the second it breaks.", red, size: 84, w: 760).arrive(p(f, 295)), w: 760)
            } else {
                dotHeadline("Know the second it's live.", green).arrive(p(f, 186), o3).at(90, 1500)
                dotHeadline("Or the second it breaks.", red).arrive(p(f, 295)).at(90, 1500)
            }
            // banners slide in from the right, out upward under the strip
            Banner(icon: a.icon, ok: true, w: 920).at(bannerX, bannerY)
                .offset(x: W * (1 - inS), y: -400 * outS)
            Banner(icon: a.icon, ok: false, w: 920).at(bannerX, bannerY)
                .offset(x: W * (1 - inF))
            Strip(building: building, angle: angle, w: W, h: sh).at(0, 0)
        }
        .opacity(old)
        // scene 5
        VStack(spacing: 0) {
            Icon(img: a.icon, size: 300).arrive(p(f, t0))
            H("DeployBar", 130).arrive(p(f, t0 + 4)).padding(.top, 36)
            body("Cloudflare and Vercel deploys in your Mac's menu bar.", 40)
                .multilineTextAlignment(.center).frame(maxWidth: 1000)
                .arrive(p(f, t0 + 8)).padding(.top, 20)
            Text("Free and open source").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 36).padding(.vertical, 16)
                .overlay(Capsule().stroke(accent, lineWidth: 3))
                .arrive(p(f, t0 + 12)).padding(.top, 48)
            Text("github.com/maestro3517/deploybar").font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                .arrive(p(f, t0 + 16)).padding(.top, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: post + social preview
@MainActor func post(_ a: Assets) -> some View {
    let sh: CGFloat = 640 * a.dark.size.height / a.dark.size.width
    let top: CGFloat = 1350 - 150 - sh
    return ZStack(alignment: .topLeading) {
        canvas
        VStack(alignment: .leading, spacing: 28) {
            H("Stop refreshing your deploy dashboard.", 92)
            body("DeployBar keeps every Cloudflare and Vercel deploy in your Mac's menu bar, and pings you the second one goes live or breaks.", 34)
                .lineSpacing(6)
        }.frame(width: 900, alignment: .leading).at(90, 130)
        Shot(img: a.dark, w: 640).at(1080 - 90 - 640, top)
        Banner(icon: a.icon, ok: true, w: 780).at(90, top + 50)
        HStack(spacing: 18) {
            Icon(img: a.icon, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text("DeployBar").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                body("Free and open source", 26)
            }
        }.at(90, 1350 - 70 - 64)
        Strip(building: false, angle: 0).at(0, 0)
    }
}

@MainActor func twitter(_ a: Assets) -> some View {
    let sh: CGFloat = 760, sw: CGFloat = 760 * a.dark.size.width / a.dark.size.height
    let sx = 1600 - 90 - sw
    return ZStack(alignment: .topLeading) {
        canvas
        VStack(alignment: .leading, spacing: 28) {
            H("Stop refreshing your deploy dashboard.", 84).frame(width: 760, alignment: .leading)
            body("DeployBar keeps every Cloudflare and Vercel deploy in your Mac's menu bar. It pops up the second a build starts, and pings you when it goes live or breaks.", 32)
                .lineSpacing(6).frame(width: 640, alignment: .leading)
        }
        .padding(.leading, 90).padding(.top, 50)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        Shot(img: a.dark, h: sh).at(sx, (900 - sh) / 2)
        StartPop(fraction: 0.62, angle: 0).at(1600 - 302 - 280, 50 + 22)
        Strip(building: true, angle: 0, w: 1600, h: 50).at(0, 0)
    }
}

@MainActor func social(_ a: Assets) -> some View {
    ZStack {
        canvas
        VStack(alignment: .leading, spacing: 0) {
            Icon(img: a.icon, size: 140)
            H("DeployBar", 96).padding(.top, 28)
            body("Your Cloudflare and Vercel deploys, in the macOS menu bar.", 34).padding(.top, 14)
        }
        .frame(width: 560, alignment: .leading).padding(.leading, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        Shot(img: a.dark, h: 560).padding(.trailing, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

// MARK: output
@MainActor func write<V: View>(_ v: V, _ w: Int, _ h: Int, _ path: String) {
    let r = ImageRenderer(content: v.frame(width: CGFloat(w), height: CGFloat(h)).clipped())
    r.scale = 1
    guard let cg = r.cgImage, cg.width == w, cg.height == h,
          let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("render failed: \(path)\n".utf8)); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

func load(_ n: String) -> NSImage {
    guard let i = NSImage(contentsOfFile: "assets/\(n)") else { FileHandle.standardError.write(Data("missing assets/\(n)\n".utf8)); exit(1) }
    return i
}

MainActor.assumeIsolated {
    let a = Assets(icon: load("icon.png"), dark: load("screenshot-dark.png"))
    write(post(a), 1080, 1350, "\(outDir)/post.png")
    write(social(a), 1280, 640, "\(outDir)/social-preview.png")
    write(twitter(a), 1600, 900, "\(outDir)/twitter.png")
    for f in 0..<450 { write(reel(f, a), 1080, 1920, String(format: "\(framesDir)/%04d.png", f)) }
    try! FileManager.default.createDirectory(atPath: "\(framesDir)-land", withIntermediateDirectories: true)
    for f in 0..<450 { write(reel(f, a, land: true), 1920, 1080, String(format: "\(framesDir)-land/%04d.png", f)) }
}
