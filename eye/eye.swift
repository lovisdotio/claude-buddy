// ClaudeBuddyEye — les « yeux » du buddy : capture une zone de l'écran, lit le texte (Vision), l'écrit dans un fichier.
// App séparée et figée : la permission d'enregistrement d'écran lui reste attachée même quand le buddy est recompilé.
// Usage : open -W -g -n -a ClaudeBuddyEye.app --args <x> <y> <w> <h> <windowID à exclure> <fichier de sortie>
// (x, y, w, h en coordonnées globales CoreGraphics, origine en haut à gauche)
import Foundation
import ScreenCaptureKit
import Vision

let a = CommandLine.arguments
guard a.count >= 7, let x = Double(a[1]), let y = Double(a[2]), let w = Double(a[3]), let h = Double(a[4]),
      let wid = UInt32(a[5]) else { exit(2) }
let out = URL(fileURLWithPath: a[6])
let rect = CGRect(x: x, y: y, width: w, height: h)

Task {
    var text = ""
    if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
       let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) }) {
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            .intersection(CGRect(origin: .zero, size: display.frame.size))
        cfg.width = Int(cfg.sourceRect.width * 2); cfg.height = Int(cfg.sourceRect.height * 2)
        let me = content.windows.filter { $0.windowID == wid }
        if let img = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: me), configuration: cfg) {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["en-US", "fr-FR"]
            try? VNImageRequestHandler(cgImage: img).perform([req])
            text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
    }
    try? text.write(to: out, atomically: true, encoding: .utf8)
    exit(0)
}
RunLoop.main.run()
