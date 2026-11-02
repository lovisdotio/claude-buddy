// Claude Buddy — petite fenêtre flottante qui joue la boucle correspondant à l'état
// écrit dans ~/claude-buddy/state (idle | thinking | talking | waiting | done | error | love | hello).
// Chaque état = un dossier clips/<état>/ ; à chaque fin de clip, une variante est tirée au hasard.
import AppKit
import AVFoundation
import Vision

let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("claude-buddy")
let stateFile = home.appendingPathComponent("state")
let speakFile = home.appendingPathComponent("speak.txt")
let ttsURL = URL(string: "https://fal.run/elevenlabs/tts/eleven-v4-turbo/stream")!   // audio en flux : 1er son en ~0,5 s

/// Lit l'audio Eleven pendant qu'il arrive (PCM 16 bits 24 kHz mono) au lieu d'attendre le fichier complet.
final class StreamSpeaker: NSObject, URLSessionDataDelegate {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    var session: URLSession!
    var task: URLSessionDataTask?
    var leftover = Data()
    var pending = 0, received = false, finished = false, failed = false, stopped = false
    var onFirstAudio: (() -> Void)?
    var onEnd: ((Bool) -> Void)?          // true = lu jusqu'au bout, false = échec
    var active: Bool { !stopped && !(finished && pending == 0) }

    init(request: URLRequest) {
        super.init()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue.main)
        task = session.dataTask(with: request)
    }
    func start() { task?.resume() }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if (response as? HTTPURLResponse)?.statusCode != 200 { failed = true; completionHandler(.cancel); end(); return }
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        var bytes = leftover + data
        if bytes.count % 2 == 1 { leftover = bytes.suffix(1); bytes = bytes.dropLast(1) } else { leftover = Data() }
        let frames = bytes.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            let dst = buf.floatChannelData![0]
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        pending += 1
        node.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.async { self?.pending -= 1; self?.checkEnd() }
        }
        if !received { received = true; onFirstAudio?() }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finished = true
        if error != nil && !received { failed = true }
        checkEnd()
    }

    func play() { if !stopped { node.play() } }

    private func checkEnd() { if finished && pending == 0 { end() } }
    private var ended = false
    private func end() {
        guard !ended else { return }
        ended = true
        let ok = received && !failed && !stopped
        stopped = true
        session.finishTasksAndInvalidate()
        onEnd?(ok)
    }

    func stop() {
        stopped = true
        task?.cancel()
        node.stop(); engine.stop()
        session.invalidateAndCancel()
    }
}
let size: CGFloat = 76
let pad: CGFloat = 22          // marge transparente autour de la boule, pour l'effet de clic

final class Clip {
    let name: String
    let player: AVPlayer
    init(url: URL) {
        name = url.deletingPathExtension().lastPathComponent
        player = AVPlayer(playerItem: AVPlayerItem(url: url))
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }
}

/// Clic = lire la réponse de sa conversation ; glisser-déposer sur un texte = lire la réponse qui contient ce texte.
final class DragView: NSView {
    var onClick: (() -> Void)?
    var onDrop: (() -> Void)?
    var dragging = false
    private var start = NSPoint.zero, origin = NSPoint.zero
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // un seul clic suffit, même sans focus
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation; origin = window?.frame.origin ?? .zero; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 6 { dragging = true }
        if dragging { window?.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { dragging = false; onDrop?() } else { onClick?() }
    }
    var onRightClick: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) { if let f = onRightClick { f(event) } else { NSApp.terminate(nil) } }
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSPanel!
    var layers = [AVPlayerLayer(), AVPlayerLayer()]   // double tampon : la suivante n'apparaît qu'une fois prête
    var front = 0
    var pendingVariant: String?
    var clips: [String: [Clip]] = [:]
    var playing: Clip?
    var lastRaw = ""
    var mood: [String] = []   // variantes préférées selon le contenu de ce qui est dit
    var current = ""
    var falKey = ""          // lue une fois via 1Password, gardée en mémoire seulement
    var audio: AVAudioPlayer?
    var sayProcess: Process?

    func applicationDidFinishLaunching(_ n: Notification) {
        let fm = FileManager.default
        let root = home.appendingPathComponent("clips")
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "mp4" }
            if !files.isEmpty { clips[dir.lastPathComponent] = files.map(Clip.init) }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { n in
            if (n.object as? AVPlayerItem) === self.playing?.player.currentItem { self.next() }
        }
        let screen = NSScreen.main!.visibleFrame
        window = NSPanel(contentRect: NSRect(x: screen.maxX - size - 24, y: screen.minY + 24, width: size + 2 * pad, height: size + 2 * pad),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        let view = DragView(frame: NSRect(x: 0, y: 0, width: size + 2 * pad, height: size + 2 * pad))
        view.wantsLayer = true
        let ball = CALayer()
        ball.frame = CGRect(x: pad, y: pad, width: size, height: size)
        ball.cornerRadius = size / 2
        ball.masksToBounds = true
        ball.shadowOpacity = 0
        view.layer?.addSublayer(ball)
        ballLayer = ball
        for (i, l) in layers.enumerated() {
            l.frame = ball.bounds
            l.videoGravity = .resizeAspectFill
            l.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
            l.opacity = i == 0 ? 1 : 0
            ball.addSublayer(l)
        }
        view.onClick = { self.clicked() }
        view.onDrop = { self.dropped() }
        view.onRightClick = { e in self.showMenu(e) }
        dragView = view
        loadAnswers()
        window.contentView = view
        // visible seulement quand VS Code est au premier plan
        let ws = NSWorkspace.shared
        updateVisibility(ws.frontmostApplication)
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            self.updateVisibility(n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        show(clips["hello"] != nil ? "hello" : "idle")
        DispatchQueue.global().async { self.falKey = self.readKey() }
        Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in self.poll() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in self.moveTick() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in self.trackWindow() }
    }

    func updateVisibility(_ app: NSRunningApplication?) {
        let editors = ["com.microsoft.VSCode"]
        if let id = app?.bundleIdentifier, editors.contains(id) { editorPid = app!.processIdentifier; follow(); window.orderFrontRegardless() }
        else if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { window.orderOut(nil) }
    }

    var editorPid: pid_t = 0

    /// Fenêtre VS Code au premier plan (la première dans l'ordre d'empilement), en repère Cocoa.
    func frontEditorWindow() -> (CGWindowID, NSRect)? {
        guard editorPid != 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainH = NSScreen.screens.first?.frame.height else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == editorPid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.width > 300, r.height > 200,
               let id = w[kCGWindowNumber as String] as? CGWindowID {
                return (id, NSRect(x: r.minX, y: mainH - r.maxY, width: r.width, height: r.height))   // CG haut-gauche → Cocoa
            }
        }
        return nil
    }

    func frontEditorRect() -> NSRect? { frontEditorWindow()?.1 }

    /// Plusieurs fenêtres VS Code : chacune garde sa place pour lui (décalage depuis son coin bas-droit).
    /// Quand on passe à une autre fenêtre, il y saute ; quand la fenêtre bouge, il la suit.
    var curWin: CGWindowID = 0, curRect = NSRect.zero, offsets: [CGWindowID: NSPoint] = [:]

    func trackWindow() {
        guard window.isVisible, placed, !(dragView?.dragging ?? false), let (id, r) = frontEditorWindow() else { return }
        if id == curWin && r == curRect { return }
        if curWin != 0 { offsets[curWin] = NSPoint(x: target.x - curRect.maxX, y: target.y - curRect.minY) }
        let off = offsets[id] ?? NSPoint(x: -size - 18, y: 14)
        let p = NSPoint(x: min(r.maxX - size - 4, max(r.minX + 4, r.maxX + off.x)), y: min(r.maxY - size - 4, max(r.minY + 4, r.minY + off.y)))
        let jump = id != curWin
        curWin = id; curRect = r
        if jump { pos = p; target = p; hopPhase = 0; place(p) } else { pos.x += p.x - target.x; pos.y += p.y - target.y; target = p; place(pos) }
    }

    // --- Déplacement : immobile, sauf quand on l'appelle (« go bot ») : il fonce vers la conversation ---
    var pos = NSPoint.zero, target = NSPoint.zero, hopPhase: CGFloat = 0, placed = false

    func follow() {
        guard !placed, let (id, r) = frontEditorWindow() else { return }
        pos = NSPoint(x: r.maxX - size - 18, y: r.minY + 14); target = pos; placed = true
        curWin = id; curRect = r
        place(pos)
    }

    /// Cible : bas de la fenêtre VS Code au premier plan, à l'aplomb de la souris (là où on vient de taper).
    func summon() {
        guard let r = frontEditorRect() else { return }
        let mouseX = NSEvent.mouseLocation.x
        let x = min(r.maxX - size - 18, max(r.minX + 18, mouseX - size / 2))
        target = NSPoint(x: x, y: r.minY + 14)
    }

    func place(_ p: NSPoint) { window.setFrameOrigin(NSPoint(x: p.x - pad, y: p.y - pad)) }

    func moveTick() {
        guard window.isVisible, placed, !(dragView?.dragging ?? false) else { return }
        let dx = target.x - pos.x, dy = target.y - pos.y, dist = hypot(dx, dy)
        guard dist > 0.5 else { if hopPhase != 0 { hopPhase = 0; place(pos) }; return }
        let step = min(dist, max(14, dist * 0.12))            // rapide, freine à l'arrivée
        pos.x += dx / dist * step; pos.y += dy / dist * step
        hopPhase += 0.35
        let hop = abs(sin(hopPhase)) * size * 0.4 * min(1, dist / 40)
        place(NSPoint(x: pos.x, y: pos.y + hop))
    }

    /// Clic : lit la dernière réponse de Claude ; re-clic pendant qu'il parle = stop.
    var ballLayer: CALayer?

    /// Effet de clic : anneau lumineux qui s'élargit + petit écrasement-rebond de la boule.
    func clickEffect() {
        guard let root = dragView?.layer, let ball = ballLayer else { return }
        for (i, delay) in [0.0, 0.12].enumerated() {
            let ring = CAShapeLayer()
            let r = size / 2
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: size, height: size), transform: nil)
            ring.position = CGPoint(x: pad + r, y: pad + r)
            ring.fillColor = nil
            ring.strokeColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.86, alpha: 1).cgColor   // rose pâle
            ring.lineWidth = i == 0 ? 3 : 2
            ring.shadowColor = ring.strokeColor; ring.shadowOpacity = 0.9; ring.shadowRadius = 6; ring.shadowOffset = .zero
            ring.opacity = 0
            root.insertSublayer(ring, below: ball)
            let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1.0; grow.toValue = (size + 2 * pad - 4) / size
            let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [0.0, 1.0, 0.0]; fade.keyTimes = [0, 0.15, 1]
            let g = CAAnimationGroup(); g.animations = [grow, fade]; g.duration = 0.55
            g.beginTime = CACurrentMediaTime() + delay
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.isRemovedOnCompletion = true
            ring.add(g, forKey: "ripple")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + delay) { ring.removeFromSuperlayer() }
        }
        let squash = CAKeyframeAnimation(keyPath: "transform.scale")
        squash.values = [1.0, 0.82, 1.12, 0.96, 1.0]
        squash.keyTimes = [0, 0.18, 0.45, 0.72, 1]
        squash.duration = 0.45
        ball.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ball.add(squash, forKey: "squash")
    }

    func clicked() {
        clickEffect()
        if voiceBusy { hush(); return }
        let pin = pinnedSession()
        if !pin.isEmpty { currentSid = pin }
        setState("thinking"); lastRaw = "thinking"; show("thinking", variant: "think-dots")
        playPrep()
        speechID += 1; fetching = true
        let id = speechID
        // la conversation derrière lui = le terminal au-dessus de la boule : on la lit à l'écran
        let f = window.frame
        // seulement le texte juste derrière/au-dessus de lui, pas tout l'écran
        let under = NSRect(x: f.midX - 450, y: f.midY - 60, width: 900, height: 120)
        let region = NSRect(x: f.midX - 380, y: f.minY, width: 760, height: 420)
        let wid = CGWindowID(window.windowNumber), mainH = NSScreen.screens.first?.frame.height ?? 0
        Task {
            let below = await self.ocr(under, excluding: wid, mainH: mainH)
            var behind = below.isEmpty ? nil : self.match(below, mode: "--under")
            if behind == nil {
                let seen = await self.ocr(region, excluding: wid, mainH: mainH)
                behind = seen.isEmpty ? nil : self.match(seen, mode: "--last")
            }
            let found = behind
            await MainActor.run {
                guard id == self.speechID else { return }          // re-clic entre-temps = annulé
                if let text = found, !text.isEmpty { self.speak(text) }
                else { self.fetching = false; self.setState("error"); self.lastRaw = "error"; self.show("error", variant: "err-confused") }
            }
        }
    }

    // --- Conversations : chaque session a son repère (où on a tapé) et sa dernière réponse ---
    var dragView: DragView?
    var anchors: [String: NSPoint] = [:]
    var answers: [String: String] = [:]
    var currentSid = ""
    var eventsOffset: UInt64 = 0
    let eventsURL = home.appendingPathComponent("events.jsonl")

    func parse(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// Au lancement : on récupère les réponses déjà connues, sans rejouer les événements.
    func loadAnswers() {
        guard let data = try? Data(contentsOf: eventsURL) else { return }
        eventsOffset = UInt64(data.count)
        let pin = pinnedSession()
        for e in parse(data) where e["ev"] as? String == "answer" { App.latestAnswer = e["text"] as? String }
        for e in parse(data) where e["ev"] as? String == "stop" {
            if let sid = e["sid"] as? String, let t = e["text"] as? String { answers[sid] = t }
        }
        currentSid = pin   // au démarrage : uniquement la conversation à laquelle il est attaché
    }

    func pinnedSession() -> String {
        (try? String(contentsOf: home.appendingPathComponent("pinned-session"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Phrase pré-enregistrée jouée tout de suite au clic, pendant que la vraie voix se prépare.
    var prepPlayer: AVAudioPlayer?
    func playPrep() {
        let dir = home.appendingPathComponent("prompts")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp3" }
        guard let f = files.randomElement(), let p = try? AVAudioPlayer(contentsOf: f) else { return }
        prepPlayer = p; p.play()
    }

    func readEvents() {
        guard let h = try? FileHandle(forReadingFrom: eventsURL) else { return }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        if end < eventsOffset { eventsOffset = 0 }
        guard end > eventsOffset else { return }
        try? h.seek(toOffset: eventsOffset)
        let data = h.readDataToEndOfFile(); eventsOffset = end
        for e in parse(data) {
            guard let ev = e["ev"] as? String, let sid = e["sid"] as? String else { continue }
            if ev == "answer", let text = e["text"] as? String { App.latestAnswer = text; continue }
            if ev == "prompt", let r = frontEditorRect() {
                // repère de la conversation : là où était la souris quand on a tapé, au bas de la fenêtre
                let x = min(r.maxX - size - 18, max(r.minX + 18, NSEvent.mouseLocation.x - size / 2))
                anchors[sid] = NSPoint(x: x, y: r.minY + 14)
            } else if ev == "stop", let text = e["text"] as? String {
                answers[sid] = text; currentSid = sid
                if let a = anchors[sid], curRect.contains(a) { target = a }               // il saute sur la conversation qui vient de répondre
                if e["speak"] as? Bool == true { speak(text) }
            }
        }
    }

    /// Lâché sur un texte : capture sous lui, OCR, et lecture de la réponse complète correspondante.
    /// Il parle, prépare sa voix ou joue la phrase d'attente.
    var voiceBusy: Bool {
        current == "talking" || fetching || (streamer?.active ?? false) || (audio?.isPlaying ?? false) || (prepPlayer?.isPlaying ?? false)
    }

    /// Arrêt total : la voix, son chargement et la phrase d'attente. Un nouveau clic relance la lecture.
    func hush() {
        speechID += 1; fetching = false
        stopVoice(); setState("idle"); lastRaw = "idle"; show("idle")
    }

    func dropped() {
        if voiceBusy { hush(); return }          // un clic un peu « glissé » pendant qu'il parle = stop, pas relecture
        pos = NSPoint(x: window.frame.minX + pad, y: window.frame.minY + pad); target = pos
        // il « s'installe » sur la conversation la plus proche
        if let (sid, _) = anchors.min(by: { hypot($0.value.x - pos.x, $0.value.y - pos.y) < hypot($1.value.x - pos.x, $1.value.y - pos.y) }) {
            currentSid = sid
        }
        stopVoice()
        setState("thinking"); lastRaw = "thinking"; show("thinking", variant: "think-scan")
        let f = window.frame
        let region = NSRect(x: f.midX - 450, y: f.midY - 60, width: 900, height: 120)   // 3-4 lignes juste sous lui
        let wid = CGWindowID(window.windowNumber), mainH = NSScreen.screens.first?.frame.height ?? 0
        Task {
            let text = await self.ocr(region, excluding: wid, mainH: mainH)
            // texte d'une conversation Claude → toute la réponse ; sinon (page web, doc…) → le texte vu sous lui
            let answer = text.isEmpty ? nil : (self.match(text, mode: "--under") ?? (text.count > 20 ? text : nil))
            await MainActor.run {
                if let a = answer { self.speak(a) }
                else { self.setState("error"); self.lastRaw = "error"; self.show("error", variant: "err-confused") }
            }
        }
    }

    /// Les « yeux » sont une app séparée et figée (ClaudeBuddyEye.app) : c'est elle qui a la permission
    /// d'enregistrement d'écran, donc recompiler le buddy ne redemande jamais l'autorisation.
    nonisolated func ocr(_ region: NSRect, excluding wid: CGWindowID, mainH: CGFloat) async -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("claude-buddy")
        let out = home.appendingPathComponent("eye-out.txt")
        try? FileManager.default.removeItem(at: out)
        let cgY = mainH - region.maxY                      // Cocoa (bas-gauche) → CG (haut-gauche)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-W", "-g", "-n", "-a", home.appendingPathComponent("eye/ClaudeBuddyEye.app").path, "--args",
                       "\(region.minX)", "\(cgY)", "\(region.width)", "\(region.height)", "\(wid)", out.path]
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    }

    nonisolated func match(_ text: String, mode: String? = nil) -> String? {
        let p = Process()
        p.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("claude-buddy/match.py")
        if let mode { p.arguments = [mode] }
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp; p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        inp.fileHandleForWriting.write(Data(text.utf8)); try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    func poll() {
        readEvents()
        explainTick()
        if let text = try? String(contentsOf: speakFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: speakFile)
            summon()
            speak(text)
        }
        let raw = (try? String(contentsOf: stateFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "idle"
        if raw != lastRaw {
            lastRaw = raw
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            let s = parts[0], variant = parts.count > 1 ? parts[1] : nil
            if s == "thinking" { speechID += 1; fetching = false; stopVoice() }
            if s != current { show(s, variant: variant) } else if let v = variant { pendingVariant = v }
        }
    }

    /// Clé fal : $FAL_KEY si présente, sinon 1Password ($BUDDY_OP_REF). Gardée en mémoire seulement.
    func readKey() -> String {
        let env0 = ProcessInfo.processInfo.environment
        if let k = env0["FAL_KEY"], !k.isEmpty { return k }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["op", "read", env0["BUDDY_OP_REF"] ?? "op://Employee/fal/credential"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let out = Pipe(); p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func setState(_ s: String) { try? s.write(to: stateFile, atomically: true, encoding: .utf8) }

    var streamer: StreamSpeaker?

    func stopVoice() {
        streamer?.onEnd = nil; streamer?.stop(); streamer = nil
        audio?.stop(); audio = nil
        prepPlayer?.stop(); prepPlayer = nil
        sayProcess?.terminate(); sayProcess = nil
    }

    var speechID = 0          // une seule lecture à la fois : la plus récente annule les autres
    var fetching = false

    func speak(_ text: String) {
        streamer?.onEnd = nil; streamer?.stop(); streamer = nil
        audio?.stop(); audio = nil
        speechID += 1
        let id = speechID
        fetching = true
        let voice = (try? String(contentsOf: home.appendingPathComponent("voice"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "George"
        DispatchQueue.global().async {
            if self.falKey.isEmpty { self.falKey = self.readKey() }
            DispatchQueue.main.async {
                guard id == self.speechID else { return }   // une lecture plus récente (ou un stop) a pris la main
                guard !self.falKey.isEmpty else { self.voiceFailed(); return }
                var req = URLRequest(url: ttsURL, timeoutInterval: 30)
                req.httpMethod = "POST"
                req.setValue("Key \(self.falKey)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject:
                    ["text": text, "voice": voice, "output_format": "pcm_24000"])
                let sp = StreamSpeaker(request: req)
                self.streamer = sp
                sp.onFirstAudio = { [weak self, weak sp] in
                    guard let self, let sp, id == self.speechID else { return }
                    self.fetching = false
                    self.startTalking(text) { sp.play() }
                }
                sp.onEnd = { [weak self] ok in
                    guard let self, id == self.speechID else { return }
                    self.fetching = false
                    if ok { self.finishTalking() } else { self.voiceFailed() }
                }
                sp.start()
            }
        }
    }

    /// La voix démarre dès le premier morceau d'audio ; si la phrase d'attente joue encore, on la laisse finir.
    func startTalking(_ text: String, go: @escaping () -> Void) {
        if prepPlayer?.isPlaying ?? false {
            let id = speechID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if id == self.speechID { self.startTalking(text, go: go) }
            }
            return
        }
        let m = moods(for: text)
        mood = m.talk; endReaction = m.end
        setState("talking"); lastRaw = "talking"; show("talking")
        go()
    }

    func voiceFailed() {
        // pas de voix de secours : si Eleven échoue, il fait juste une tête perplexe
        fetching = false
        setState("error"); lastRaw = "error"; show("error", variant: "err-confused")
        if falKey.isEmpty { DispatchQueue.global().async { self.falKey = self.readKey() } }
    }

    func finishTalking() {
        guard current == "talking" else { return }
        let cat = endReaction.hasPrefix("err") ? "error" : endReaction.hasPrefix("wait") ? "waiting" : "done"
        setState("done"); lastRaw = "done"; show(cat, variant: endReaction); current = "done"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.current == "done" { self.setState("idle"); self.show("idle") }
        }
    }

    func waitThenDone(_ busy: @escaping () -> Bool) {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            if busy() { return }
            t.invalidate()
            guard self.current == "talking" else { return }
            let cat = self.endReaction.hasPrefix("err") ? "error" : self.endReaction.hasPrefix("wait") ? "waiting" : "done"
            self.setState("done"); self.lastRaw = "done"; self.show(cat, variant: self.endReaction); self.current = "done"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.current == "done" { self.setState("idle"); self.show("idle") }
            }
        }
    }

    func show(_ s: String, variant: String? = nil) {
        current = s
        pendingVariant = nil
        if s != "talking" { mood = [] }
        if let v = variant, let c = clips[s]?.first(where: { $0.name == v }) { play(c) } else { play(pick(s)) }
    }

    /// Choisit les variantes « parle » et la réaction de fin d'après le texte.
    func moods(for text: String) -> (talk: [String], end: String) {
        let t = text.lowercased()
        let bad = ["erreur", "échou", "échec", "bloqué", "impossible", "problème", "cassé", "error", "failed", "broken", "denied", "refus"]
        let good = ["fini", "prêt", "terminé", "ça marche", "réussi", "parfait", "bravo", "done", "ready", "works", "✅"]
        if bad.contains(where: t.contains) { return (["talk-serious", "talk-explain"], ["err-sad", "err-oops"].randomElement()!) }
        if t.filter({ $0 == "?" }).count >= 1 && t.trimmingCharacters(in: .whitespaces).hasSuffix("?") {
            return (["talk-question", "talk-explain", "talk-lean"], "wait-puppy")
        }
        if good.contains(where: t.contains) || t.contains("!") {
            return (["talk-excited", "talk-laugh", "talk-explain"], ["done-cheer", "done-proud", "done-dance", "done-wink"].randomElement()!)
        }
        return (["talk-explain", "talk-sway", "talk-lean", "base"], ["done-proud", "done-wink"].randomElement()!)
    }
    var endReaction = "base"

    /// Variante au hasard ; en attente, la boucle de base revient plus souvent pour rester calme.
    func pick(_ s: String) -> Clip? {
        guard let list = clips[s] ?? clips["idle"], !list.isEmpty else { return nil }
        if s == "talking", !mood.isEmpty {
            let pref = list.filter { mood.contains($0.name) && $0 !== playing }
            if let c = pref.randomElement() { return c }
        }
        if s == "idle", Double.random(in: 0..<1) < 0.6, let base = list.first(where: { $0.name == "base" }) { return base }
        let others = list.filter { $0 !== playing }
        return (others.isEmpty ? list : others).randomElement()
    }

    func next() {
        // hello, error et love ne jouent qu'une fois, puis on retombe en attente
        if ["hello", "error", "love"].contains(current) { setState("idle"); lastRaw = "idle"; show("idle"); return }
        if let v = pendingVariant, let c = clips[current]?.first(where: { $0.name == v }) {
            pendingVariant = nil; play(c); return
        }
        play(pick(current))
    }

    func play(_ clip: Clip?) {
        guard let clip else { return }
        if clip === playing {
            clip.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in clip.player.play() }
            return
        }
        let old = playing
        playing = clip
        let back = layers[1 - front], top = layers[front]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        back.player = clip.player
        CATransaction.commit()
        clip.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                guard self.playing === clip else { return }
                clip.player.play()
                self.whenReady(back) {
                    guard self.playing === clip else { return }
                    back.zPosition = 1; top.zPosition = 0
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.15)
                    CATransaction.setCompletionBlock {
                        guard self.playing === clip else { return }
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        top.opacity = 0
                        CATransaction.commit()
                        old?.player.pause()
                    }
                    back.opacity = 1
                    CATransaction.commit()
                    self.front = 1 - self.front
                }
            }
        }
    }

    func whenReady(_ l: AVPlayerLayer, tries: Int = 0, _ go: @escaping () -> Void) {
        if l.isReadyForDisplay || tries > 30 { go(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { self.whenReady(l, tries: tries + 1, go) }
    }
}

// ============================================================================
// Mode vidéo 1939 : clic droit → panneau de sélection → clips H3 Max joués dans une grande bulle.
// Le moteur est explain/explain.py (découpage ~60 mots, scènes par LLM, 3 clips générés en avance).
// ============================================================================
let explainDir = home.appendingPathComponent("explain")

func money(_ v: Double) -> String { String(format: "$%.2f", v) }

/// Petite étiquette sous le bot : combien de vidéos, combien de mots, premiers et derniers mots, puis Lancer.
final class ExplainPanel: NSObject {
    let panel: NSPanel
    let text: String
    var onLaunch: ((String, String) -> Void)?

    init(text: String, near ball: NSRect) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = self.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let clips = max(1, Int((Double(words.count) / 60).rounded(.up)))
        let W: CGFloat = 330, H: CGFloat = 96
        let vis = NSScreen.main?.visibleFrame ?? .zero
        var x = ball.maxX - W
        x = min(vis.maxX - W - 6, max(vis.minX + 6, x))
        // juste en dessous du bot ; s'il n'y a pas la place (bas de l'écran), juste au-dessus
        let y = ball.minY - H - 6 >= vis.minY ? ball.minY - H - 6 : ball.maxY + 6
        panel = NSPanel(contentRect: NSRect(x: x, y: y, width: W, height: H),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.96).cgColor
        v.layer?.cornerRadius = 12
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.86, alpha: 0.55).cgColor
        panel.contentView = v

        func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color
            l.lineBreakMode = .byTruncatingMiddle
            l.frame = NSRect(x: 14, y: y, width: W - 28, height: size + 6)
            v.addSubview(l)
        }
        let head = words.isEmpty ? "No answer to read yet." :
            "\(clips) video\(clips > 1 ? "s" : "") · \(words.count) words · ~\(clips * 15)s · ~\(money(Double(clips) * 0.75))"
        label(head, 14, .semibold, .white, y: H - 30)
        if !words.isEmpty {
            let a = words.prefix(4).joined(separator: " "), b = words.suffix(4).joined(separator: " ")
            label("“\(a) … \(b)”", 12, .regular, NSColor(calibratedWhite: 0.78, alpha: 1), y: H - 52)
        }
        let full = NSButton(title: "▶ Read all", target: self, action: #selector(fullTap))
        let summary = NSButton(title: "Summary", target: self, action: #selector(summaryTap))
        let cancel = NSButton(title: "✕", target: self, action: #selector(cancelTap))
        full.frame = NSRect(x: 10, y: 8, width: 120, height: 28)
        summary.frame = NSRect(x: 134, y: 8, width: 100, height: 28)
        cancel.frame = NSRect(x: W - 46, y: 8, width: 36, height: 28)
        for b in [full, summary, cancel] { b.bezelStyle = .rounded; b.isEnabled = !words.isEmpty || b === cancel; v.addSubview(b) }
        full.keyEquivalent = "\r"
    }

    func go(_ mode: String) { panel.orderOut(nil); if !text.isEmpty { onLaunch?(text, mode) } }
    @objc func fullTap() { go("full") }
    @objc func summaryTap() { go("summary") }
    @objc func cancelTap() { panel.orderOut(nil) }
}

final class TapView: NSView {
    var onTap: (() -> Void)?
    private var start = NSPoint.zero, origin = NSPoint.zero, dragging = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation; origin = window?.frame.origin ?? .zero; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 6 { dragging = true }
        if dragging { window?.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y)) }
    }
    override func mouseUp(with event: NSEvent) { if !dragging { onTap?() }; dragging = false }
}

/// La boule s'ouvre en grand cercle et joue les clips à la suite, avec le son ; anneau rose = avancement.
final class VideoBubble: NSObject {
    let D: CGFloat = 380, m: CGFloat = 16
    let panel: NSPanel
    let group = CALayer()
    let player = AVQueuePlayer()
    let progress = CAShapeLayer()
    var durations: [Double] = []
    var played = 0, queued = 0
    var expected = Int.max            // nombre de clips à jouer avant de se refermer
    var onFinish: (() -> Void)?
    var timer: Timer?
    var closing = false
    var waiting = false                // fin d'un clip, le suivant n'est pas encore prêt
    let loader = CALayer()             // petit chargement posé sur la dernière image

    init(ball: NSRect, smallSize: CGFloat) {
        let vis = NSScreen.main?.visibleFrame ?? .zero
        var b = NSRect(x: ball.maxX - D, y: ball.minY, width: D, height: D)      // grandit vers le haut-gauche
        b.origin.x = min(vis.maxX - D - 8, max(vis.minX + 8, b.origin.x))
        b.origin.y = min(vis.maxY - D - 8, max(vis.minY + 8, b.origin.y))
        panel = NSPanel(contentRect: b.insetBy(dx: -m, dy: -m), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        let v = TapView(frame: NSRect(x: 0, y: 0, width: D + 2 * m, height: D + 2 * m))
        v.wantsLayer = true
        panel.contentView = v

        group.frame = CGRect(x: m, y: m, width: D, height: D)
        // le grand cercle naît exactement là où était la petite boule
        let c = CGPoint(x: ball.midX - b.minX, y: ball.midY - b.minY)
        group.anchorPoint = CGPoint(x: c.x / D, y: c.y / D)
        group.position = CGPoint(x: m + c.x, y: m + c.y)
        group.shadowColor = NSColor.black.cgColor; group.shadowOpacity = 0.45; group.shadowRadius = 10; group.shadowOffset = .zero
        v.layer?.addSublayer(group)

        let disc = CALayer()
        disc.frame = group.bounds; disc.cornerRadius = D / 2; disc.masksToBounds = true
        disc.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1).cgColor
        let pl = AVPlayerLayer(player: player)
        pl.frame = disc.bounds; pl.videoGravity = .resizeAspectFill
        disc.addSublayer(pl)
        group.addSublayer(disc)

        let ring = CAShapeLayer()            // cercle noir autour
        ring.path = CGPath(ellipseIn: group.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ring.fillColor = nil; ring.strokeColor = NSColor(calibratedWhite: 0.05, alpha: 1).cgColor; ring.lineWidth = 5
        group.addSublayer(ring)
        // avancement : arc rose pâle, part du haut, sens horaire
        let r = D / 2 - 2
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: D / 2, y: D / 2), radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        progress.path = path
        progress.fillColor = nil
        progress.strokeColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.86, alpha: 1).cgColor
        progress.lineWidth = 3; progress.lineCap = .round; progress.strokeEnd = 0
        group.addSublayer(progress)

        // petit chargement : pastille sombre + arc rose qui tourne, au centre de la dernière image
        let L: CGFloat = 54
        loader.frame = CGRect(x: (D - L) / 2, y: (D - L) / 2, width: L, height: L)
        loader.cornerRadius = L / 2
        loader.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        let arc = CAShapeLayer()
        arc.frame = loader.bounds
        arc.path = CGPath(ellipseIn: loader.bounds.insetBy(dx: 12, dy: 12), transform: nil)
        arc.fillColor = nil; arc.lineWidth = 3.5; arc.lineCap = .round
        arc.strokeColor = NSColor(calibratedRed: 1, green: 0.78, blue: 0.86, alpha: 1).cgColor
        arc.strokeStart = 0; arc.strokeEnd = 0.3
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = -2 * Double.pi; spin.duration = 0.9; spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
        loader.addSublayer(arc)
        loader.opacity = 0
        group.addSublayer(loader)
        player.actionAtItemEnd = .pause       // on avance à la main : sans clip suivant, la dernière image reste affichée

        v.onTap = { [weak self] in self?.close() }
        NotificationCenter.default.addObserver(self, selector: #selector(itemEnded(_:)), name: .AVPlayerItemDidPlayToEndTime, object: nil)

        panel.orderFrontRegardless()
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = smallSize / D; grow.toValue = 1
        grow.damping = 16; grow.stiffness = 180; grow.mass = 1
        grow.duration = grow.settlingDuration
        group.add(grow, forKey: "grow")
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func add(_ url: URL) {
        let item = AVPlayerItem(url: url)
        queued += 1
        if player.items().isEmpty { player.insert(item, after: nil); player.play(); return }
        player.insert(item, after: player.items().last)
        if waiting { advance() }               // on attendait ce clip : on repart tout de suite
    }

    func advance() {
        waiting = false
        setLoader(false)
        player.advanceToNextItem()
        player.play()
    }

    func setLoader(_ on: Bool) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
        loader.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    @objc func itemEnded(_ n: Notification) {
        // les boucles muettes du bot envoient aussi cette notification : on ne compte que nos clips
        guard let item = n.object as? AVPlayerItem, (item.asset as? AVURLAsset)?.url.path.contains("/explain/runs/") == true else { return }
        played += 1
        if played >= expected { close(); return }
        if player.items().count > 1 { advance() }      // le clip suivant est prêt : on enchaîne
        else { waiting = true; setLoader(true) }       // sinon : dernière image + petit chargement, add() relancera
    }

    func tick() {
        let total = durations.reduce(0, +)
        guard total > 0 else { return }
        let done = durations.prefix(played).reduce(0, +)
        let cur = player.currentItem.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        progress.strokeEnd = CGFloat(min(1, (done + (cur.isFinite ? cur : 0)) / total))
        CATransaction.commit()
    }

    func close() {
        guard !closing else { return }
        closing = true
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1; shrink.toValue = 0.14; shrink.duration = 0.28
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.28
        group.transform = CATransform3DMakeScale(0.14, 0.14, 1); group.opacity = 0
        group.add(shrink, forKey: "shrink"); group.add(fade, forKey: "fade")
        // la voix baisse avec la fermeture
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.player.volume = max(0, self.player.volume - 0.12)
            if self.player.volume <= 0 { t.invalidate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            self.player.pause(); self.player.removeAllItems()
            self.panel.orderOut(nil)
            self.onFinish?()
        }
    }
}

extension App {
    // État du mode vidéo (stocké globalement : une extension ne peut pas ajouter de propriétés)
    static var explainPanel: ExplainPanel?
    static var latestAnswer: String?
    static var bubble: VideoBubble?
    static var run: (dir: URL, process: Process, next: Int)?

    func ballRect() -> NSRect { let f = window.frame; return NSRect(x: f.minX + pad, y: f.minY + pad, width: size, height: size) }

    func showMenu(_ e: NSEvent) {
        let menu = NSMenu()
        let a = NSMenuItem(title: "1939 video mode…", action: #selector(openExplain), keyEquivalent: ""); a.target = self
        menu.addItem(a)
        if App.run != nil || App.bubble != nil {
            let s = NSMenuItem(title: "Stop video", action: #selector(stopExplain), keyEquivalent: ""); s.target = self
            menu.addItem(s)
        }
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit buddy", action: #selector(quitBuddy), keyEquivalent: ""); q.target = self
        menu.addItem(q)
        if let v = dragView { NSMenu.popUpContextMenu(menu, with: e, for: v) }
    }

    @objc func quitBuddy() { NSApp.terminate(nil) }

    /// Ouvre le panneau avec la dernière réponse de la conversation suivie (modifiable, sélectionnable).
    @objc func openExplain() {
        App.explainPanel?.panel.orderOut(nil)
        if voiceBusy { hush() }
        show("thinking", variant: "think-scan")
        let f = window.frame
        let under = NSRect(x: f.midX - 450, y: f.midY - 60, width: 900, height: 120)
        let region = NSRect(x: f.midX - 380, y: f.minY, width: 760, height: 420)
        let wid = CGWindowID(window.windowNumber), mainH = NSScreen.screens.first?.frame.height ?? 0
        Task {
            // d'abord la réponse juste sous lui, sinon la dernière réponse visible derrière lui
            let below = await self.ocr(under, excluding: wid, mainH: mainH)
            var behind = below.isEmpty ? nil : self.match(below, mode: "--under")
            if behind == nil {
                let seen = await self.ocr(region, excluding: wid, mainH: mainH)
                behind = seen.isEmpty ? nil : self.match(seen, mode: "--last")
            }
            let found = behind
            await MainActor.run {
                self.show("idle")
                guard let text = found, !text.isEmpty else { self.show("error", variant: "err-confused"); return }
                let p = ExplainPanel(text: text, near: self.ballRect())
                p.onLaunch = { [weak self] t, mode in self?.launchExplain(t, mode: mode) }
                App.explainPanel = p
                p.panel.orderFrontRegardless()
            }
        }
    }

    func launchExplain(_ text: String, mode: String) {
        stopExplain()
        speechID += 1; fetching = false; stopVoice()
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let dir = explainDir.appendingPathComponent("runs/\(fmt.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent("input.txt"), atomically: true, encoding: .utf8)
        show("thinking", variant: "think-spin")
        DispatchQueue.global().async {
            if self.falKey.isEmpty { self.falKey = self.readKey() }
            DispatchQueue.main.async {
                guard !self.falKey.isEmpty else { self.explainFailed(); return }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")
                p.arguments = [explainDir.appendingPathComponent("explain.py").path, mode, dir.path]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                env["FAL_KEY"] = self.falKey                 // en mémoire seulement, jamais écrite sur disque
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = try? FileHandle(forWritingTo: { let f = dir.appendingPathComponent("log.txt")
                    FileManager.default.createFile(atPath: f.path, contents: nil); return f }())
                guard (try? p.run()) != nil else { self.explainFailed(); return }
                App.run = (dir, p, 0)
            }
        }
    }

    /// Appelé toutes les 80 ms : ajoute à la bulle les clips prêts, dans l'ordre.
    func explainTick() {
        guard let run = App.run,
              let data = try? Data(contentsOf: run.dir.appendingPathComponent("status.json")),
              let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let total = st["total"] as? Int ?? 0
        let finished = st["finished"] as? Bool ?? false
        let failed = st["error"] is String
        var next = run.next
        while next < total, FileManager.default.fileExists(atPath: run.dir.appendingPathComponent(String(format: "%02d.mp4", next)).path) {
            if App.bubble == nil {
                let b = VideoBubble(ball: ballRect(), smallSize: size)
                b.onFinish = { [weak self] in self?.bubbleClosed() }
                App.bubble = b
                window.alphaValue = 0                       // la petite boule « devient » la bulle
            }
            App.bubble?.durations = (st["durations"] as? [Double]) ?? []
            App.bubble?.add(run.dir.appendingPathComponent(String(format: "%02d.mp4", next)))
            next += 1
        }
        App.run?.next = next
        if let b = App.bubble { b.durations = (st["durations"] as? [Double]) ?? b.durations; if total > 0 && next >= total { b.expected = total } }
        if finished && failed {
            // un clip a échoué : on joue ce qui est arrivé dans l'ordre, puis on se referme
            if let b = App.bubble { b.expected = next; if b.played >= next { b.close() } } else { explainFailed() }
            App.run = nil
        } else if finished {
            App.run = nil
        }
    }

    @objc func stopExplain() {
        if let r = App.run { r.process.terminate(); App.run = nil }   // plus aucun nouveau clip lancé (donc payé)
        App.bubble?.close()
    }

    func bubbleClosed() {
        App.bubble = nil
        if let r = App.run { r.process.terminate(); App.run = nil }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; window.animator().alphaValue = 1 }
        show("done", variant: "done-proud")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.current == "done" { self.show("idle") } }
    }

    func explainFailed() {
        App.run = nil
        window.alphaValue = 1
        show("error", variant: "err-confused")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
