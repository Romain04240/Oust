// Rendu SVG → PNG par WebKit, sans dépendance tierce.
//
// Pourquoi WebKit plutôt que `sips` ou `qlmanage` : CoreSVG (utilisé par NSImage et
// sips) ignore une partie des filtres (flou gaussien, mélanges) dont l'icône se sert
// pour son rendu « verre ». WebKit rend le SVG exactement comme Safari.
//
// Usage :
//   swiftc -O rendu-svg.swift -o rendu-svg
//   ./rendu-svg entree.svg sortie.png 1024 [entree2.svg sortie2.png 2320x1480 …]
//
// Chaque PNG fait exactement la taille demandée en pixels (carré ou LxH), fond transparent.

import AppKit
import WebKit

struct Job {
    let svg: URL
    let png: URL
    let width: Int
    let height: Int
}

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    private var jobs: [Job]
    private let webView: WKWebView
    private let window: NSWindow
    private var current: Job?

    init(jobs: [Job]) {
        self.jobs = jobs
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        // Une fenêtre hors écran garantit que WebKit peint réellement la vue.
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1024, height: 1024),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = webView
        window.orderBack(nil)
        super.init()
        webView.navigationDelegate = self
    }

    func next() {
        guard !jobs.isEmpty else {
            NSApp.terminate(nil)
            return
        }
        let job = jobs.removeFirst()
        current = job
        // On rend à 1024 points minimum puis on réduit : le lissage de WebKit est
        // meilleur qu'un rendu natif minuscule, et le flou garde la même portée.
        let scale = max(1, 1024 / Double(min(job.width, job.height)))
        let cw = Int((Double(job.width) * scale).rounded()), ch = Int((Double(job.height) * scale).rounded())
        webView.setFrameSize(NSSize(width: cw, height: ch))
        window.setContentSize(NSSize(width: cw, height: ch))
        // Le SVG est lu ici et passé en data URI : le processus de rendu de WebKit,
        // bac à sable oblige, n'a pas accès à tous les dossiers de l'utilisateur.
        guard let data = try? Data(contentsOf: job.svg) else {
            FileHandle.standardError.write("Lecture impossible : \(job.svg.path)\n".data(using: .utf8)!)
            exit(1)
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        img{display:block;width:\(cw)px;height:\(ch)px}</style></head>
        <body><img src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Laisse une frame pour que l'image décodée soit peinte.
            try? await Task.sleep(for: .milliseconds(250))
            self.snapshot()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write("Échec : \(error)\n".data(using: .utf8)!)
        exit(1)
    }

    private func snapshot() {
        guard let job = current else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { image, error in
            guard let image else {
                FileHandle.standardError.write("Capture impossible : \(String(describing: error))\n".data(using: .utf8)!)
                exit(1)
            }
            Self.write(image, to: job.png, width: job.width, height: job.height)
            print("✓ \(job.png.lastPathComponent) (\(job.width)×\(job.height) px)")
            self.next()
        }
    }

    private static func write(_ image: NSImage, to url: URL, width: Int, height: Int) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        ctx.imageInterpolation = .high
        NSGraphicsContext.current = ctx
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        // sRGB explicite : l'appiconset et les aperçus doivent afficher les mêmes teintes.
        let srgb = rep.converting(to: .sRGB, renderingIntent: .perceptual) ?? rep
        let data = srgb.representation(using: .png, properties: [:])!
        try! data.write(to: url)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, args.count % 3 == 0 else {
    print("Usage : rendu-svg entree.svg sortie.png taille [entree.svg sortie.png taille …]")
    exit(2)
}
var jobs: [Job] = []
for i in stride(from: 0, to: args.count, by: 3) {
    let svg = URL(fileURLWithPath: args[i]).standardizedFileURL
    let png = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
    let dims = args[i + 2].split(separator: "x").compactMap { Int($0) }
    guard (1...2).contains(dims.count), dims.allSatisfy({ $0 > 0 }) else {
        print("Taille invalide : \(args[i + 2])"); exit(2)
    }
    jobs.append(Job(svg: svg, png: png, width: dims[0], height: dims.last!))
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = MainActor.assumeIsolated { Renderer(jobs: jobs) }
DispatchQueue.main.async { MainActor.assumeIsolated { renderer.next() } }
app.run()
