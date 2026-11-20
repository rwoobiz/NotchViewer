import AppKit
import LocalAuthentication
import Security

// MARK: self test (swift run -c release NotchViewer --selftest)
if CommandLine.arguments.contains("--selftest") {
    let r = BigUInt.modPow(BigUInt(4), BigUInt(13), BigUInt(497))
    precondition(r.w == [445], "modPow small case failed: \(r.w)")
    let big = BigUInt.modPow(BigUInt(2), BigUInt(1000), BigUInt(UInt32.max)) // 2^1000 mod (2^32-1) = 2^(1000 mod 32)=2^8
    precondition(big.w == [256], "modPow 2^1000 mod 2^32-1 failed: \(big.w)")
    let mod = BigUInt(bytes: [0xc3, 0x5a, 0x91, 0x7d, 0x22, 0x10, 0xfe, 0x4b, 0x99, 0x01, 0x6e, 0x35, 0xa7, 0xd4, 0x58, 0x6f, 0x13])
    let ex = BigUInt(bytes: [0x0f, 0xa1, 0x33, 0x77, 0x12, 0xcd, 0x45, 0x08, 0x9b])
    let bs = BigUInt(bytes: [0x07, 0xaa, 0x55, 0x31, 0x99, 0x42, 0x10, 0x03, 0x77, 0x21, 0x65, 0x0a])
    precondition(BigUInt.modPow(bs, ex, mod).w == BigUInt.slowModPow(bs, ex, mod).w, "montgomery modPow mismatch")
    print("selftest ok"); exit(0)
}

enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NotchViewer.log")
    static func write(_ m: String) {
        let line = "\(Date()) \(m)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: saved login (Keychain, released with Touch ID)

enum Keychain {
    static let service = "dev.notchviewer.login"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func save(_ password: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account); q[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func exists(_ account: String) -> Bool { // no data read, so no prompt
        SecItemCopyMatching(query(account) as CFDictionary, nil) == errSecSuccess
    }
    static func load(_ account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

// MARK: keysyms

func keysym(for event: NSEvent) -> UInt32? {
    switch event.keyCode {
    case 36, 76: return 0xff0d
    case 48: return 0xff09
    case 51: return 0xff08
    case 53: return 0xff1b
    case 117: return 0xffff
    case 123: return 0xff51
    case 126: return 0xff52
    case 124: return 0xff53
    case 125: return 0xff54
    case 115: return 0xff50
    case 119: return 0xff57
    case 116: return 0xff55
    case 121: return 0xff56
    case 122: return 0xffbe; case 120: return 0xffbf; case 99: return 0xffc0; case 118: return 0xffc1
    case 96: return 0xffc2; case 97: return 0xffc3; case 98: return 0xffc4; case 100: return 0xffc5
    case 101: return 0xffc6; case 109: return 0xffc7; case 103: return 0xffc8; case 111: return 0xffc9
    default: break
    }
    guard let s = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
    let v = s.value
    if v < 0x20 || (0xf700...0xf8ff).contains(v) { return nil }
    return v < 0x100 ? v : 0x0100_0000 + v
}

let modifierKeys: [UInt16: (UInt32, NSEvent.ModifierFlags)] = [
    56: (0xffe1, .shift), 60: (0xffe2, .shift),
    59: (0xffe3, .control), 62: (0xffe4, .control),
    58: (0xffe9, .option), 61: (0xffea, .option),
    55: (0xffeb, .command), 54: (0xffec, .command),
]

// MARK: viewer

final class ViewerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var onDisconnect: (() -> Void)?
    var onCycleColour: (() -> Void)?
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, e.modifierFlags.isSuperset(of: [.control, .option, .command]), e.keyCode == 8 { onCycleColour?(); return }
        if e.type == .keyDown, e.modifierFlags.isSuperset(of: [.control, .option, .command]), e.keyCode == 12 { onDisconnect?(); return }
        super.sendEvent(e)
    }
    // Allow the window to sit over the menu bar / camera housing row.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class RemoteView: NSView {
    var client: RFBClient?
    var onDisconnect: (() -> Void)?
    private var buttons = 0
    private var scrollAcc: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.isOpaque = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    let overlay = NSTextField(labelWithString: "")
    // The shared-surface path left stale pixels on screen, so the image-copy path is the default.
    private let legacyDraw = !UserDefaults.standard.bool(forKey: "fastDraw")
    private var tempMessage: String?
    /// Control-Option-Command-C: cycle the colour handling so you can match the 16" by eye.
    func cycleColour() {
        let order: [String?] = [nil, "p3", "srgb"]
        let cur = UserDefaults.standard.string(forKey: "colorSpace")
        let next = order[((order.firstIndex(of: cur) ?? 0) + 1) % order.count]
        if let next { UserDefaults.standard.set(next, forKey: "colorSpace") } else { UserDefaults.standard.removeObject(forKey: "colorSpace") }
        let name = next == "p3" ? "Display P3" : next == "srgb" ? "sRGB" : "Pass-through (default)"
        if overlay.superview == nil { installOverlay() }
        tempMessage = "Colour: \(name)\nCtrl-Opt-Cmd-C cycles colour modes"
        overlay.stringValue = tempMessage!; overlay.isHidden = false
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.tempMessage = nil; self?.overlay.isHidden = true }
    }
    func installOverlay() {
        overlay.textColor = .white; overlay.backgroundColor = NSColor.black.withAlphaComponent(0.7); overlay.drawsBackground = true
        overlay.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        overlay.frame = NSRect(x: 20, y: bounds.height - 120, width: 520, height: 90)
        overlay.maximumNumberOfLines = 5
        addSubview(overlay)
    }
    func refresh() {
        // Default: hand the GPU the shared surface directly (no per-frame copy).
        // `defaults write dev.notchviewer.app fastDraw -bool true` tries the experimental shared-surface path.
        let surf: AnyObject? = legacyDraw ? client?.makeImage() : client?.displaySurface
        layer?.contents = surf
        if let t = tempMessage { overlay.stringValue = t }
        else if let c = client, !overlay.isHidden {
            overlay.stringValue = "NotchViewer connected \(c.width)x\(c.height)\nupdates: \(c.updates) rects: \(c.rects) lastEnc: \(c.lastEncoding)\nnon-black samples: \(c.nonBlackSample())  image: \(surf == nil ? "nil" : "ok")\nCtrl-Opt-Cmd-Q disconnects" + (c.nonBlackSample() == 0 && c.updates > 0 ? "\nAll black? Leave Username empty and use the 16\" VNC password." : "")
        }
    }

    private func remotePoint(_ e: NSEvent) -> (Int, Int) {
        guard let c = client, c.width > 0, c.height > 0 else { return (0, 0) }
        let p = convert(e.locationInWindow, from: nil)
        let scale = min(bounds.width / CGFloat(c.width), bounds.height / CGFloat(c.height))
        let rw = CGFloat(c.width) * scale, rh = CGFloat(c.height) * scale
        let ox = (bounds.width - rw) / 2, oy = (bounds.height - rh) / 2
        return (Int((p.x - ox) / scale), Int((rh - (p.y - oy)) / scale))
    }

    private func pointer(_ e: NSEvent) { let (x, y) = remotePoint(e); client?.sendPointer(x: x, y: y, buttons: buttons) }
    override func mouseMoved(with e: NSEvent) { pointer(e) }
    override func mouseDragged(with e: NSEvent) { pointer(e) }
    override func rightMouseDragged(with e: NSEvent) { pointer(e) }
    override func otherMouseDragged(with e: NSEvent) { pointer(e) }
    override func mouseDown(with e: NSEvent) { buttons |= 1; pointer(e) }
    override func mouseUp(with e: NSEvent) { buttons &= ~1; pointer(e) }
    override func rightMouseDown(with e: NSEvent) { buttons |= 4; pointer(e) }
    override func rightMouseUp(with e: NSEvent) { buttons &= ~4; pointer(e) }
    override func otherMouseDown(with e: NSEvent) { buttons |= 2; pointer(e) }
    override func otherMouseUp(with e: NSEvent) { buttons &= ~2; pointer(e) }

    override func scrollWheel(with e: NSEvent) {
        scrollAcc += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : e.scrollingDeltaY
        let (x, y) = remotePoint(e)
        while abs(scrollAcc) >= 1 {
            let bit = scrollAcc > 0 ? 8 : 16
            client?.sendPointer(x: x, y: y, buttons: buttons | bit)
            client?.sendPointer(x: x, y: y, buttons: buttons)
            scrollAcc += scrollAcc > 0 ? -1 : 1
        }
    }

    // Local escape hatch: Control-Option-Command-Q disconnects.
    private func isDisconnectCombo(_ e: NSEvent) -> Bool {
        e.modifierFlags.isSuperset(of: [.control, .option, .command]) && e.keyCode == 12
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if isDisconnectCombo(e) { onDisconnect?(); return true }
        keyDown(with: e); return true // forward Command shortcuts to the remote Mac
    }

    override func keyDown(with e: NSEvent) {
        if isDisconnectCombo(e) { onDisconnect?(); return }
        if let k = keysym(for: e) { client?.sendKey(k, down: true) }
    }
    override func keyUp(with e: NSEvent) { if let k = keysym(for: e) { client?.sendKey(k, down: false) } }
    override func flagsChanged(with e: NSEvent) {
        guard let (k, flag) = modifierKeys[e.keyCode] else { return }
        client?.sendKey(k, down: e.modifierFlags.contains(flag))
    }
}

// MARK: app

final class AppDelegate: NSObject, NSApplicationDelegate, RFBClientDelegate {
    private var connectWindow: NSWindow!
    private let hostField = NSTextField(string: UserDefaults.standard.string(forKey: "host") ?? "")
    private let userField = NSTextField(string: UserDefaults.standard.string(forKey: "user") ?? "")
    private let passField = NSSecureTextField()
    private let status = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Connect", target: nil, action: nil)
    private let touchButton = NSButton(title: "Connect with Touch ID", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget saved login", target: nil, action: nil)
    private let remember = NSButton(checkboxWithTitle: "Remember this login (unlock with Touch ID)", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let linkLabel = NSTextField(labelWithString: "")
    private lazy var linkRow: NSStackView = {
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        linkLabel.textColor = .secondaryLabelColor; linkLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let r = NSStackView(views: [spinner, linkLabel]); r.orientation = .horizontal; r.spacing = 8
        r.isHidden = true
        return r
    }()
    /// Shows a swirl and a short message while linking; nil hides it.
    private func setLinking(_ text: String?) {
        if let text {
            linkLabel.stringValue = text; linkRow.isHidden = false; spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil); linkRow.isHidden = true
        }
    }
    private var pendingPassword: String?
    private var lastPassword = ""
    private var retries = 0
    private var retrying = false
    private var account: String { "\(userField.stringValue)@\(hostField.stringValue.trimmingCharacters(in: .whitespaces))" }
    private var client: RFBClient?
    private var viewer: ViewerWindow?
    private var view: RemoteView?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildConnectWindow()
        NSApp.activate(ignoringOtherApps: true)
        if !touchButton.isHidden { touchConnect() } // saved login: ask for Touch ID straight away
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    private func buildConnectWindow() {
        connectWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        connectWindow.titlebarAppearsTransparent = true
        connectWindow.titleVisibility = .hidden
        connectWindow.isMovableByWindowBackground = true
        connectWindow.isOpaque = false
        connectWindow.backgroundColor = .clear
        connectWindow.center()

        // Same artwork as the app icon, so the window and the Dock agree.
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let title = NSTextField(labelWithString: "NotchViewer")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let sub = NSTextField(labelWithString: "Your other Mac, edge to edge.")
        sub.textColor = .secondaryLabelColor

        hostField.placeholderString = "Remote Mac address, e.g. 192.168.1.20"
        userField.placeholderString = "Username (blank for VNC password)"
        userField.placeholderString = "Username on the remote Mac (blank = VNC password)"
        passField.placeholderString = "Password"
        for f in [hostField, userField, passField] {
            f.bezelStyle = .roundedBezel; f.controlSize = .large; f.font = .systemFont(ofSize: 14)
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        remember.controlSize = .small
        status.textColor = .systemRed; status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 2
        status.font = .systemFont(ofSize: 12)
        status.widthAnchor.constraint(equalToConstant: 320).isActive = true

        button.target = self; button.action = #selector(connect)
        touchButton.target = self; touchButton.action = #selector(touchConnect)
        forgetButton.target = self; forgetButton.action = #selector(forget)
        forgetButton.bezelStyle = .inline; forgetButton.controlSize = .small; forgetButton.isBordered = false
        forgetButton.contentTintColor = .secondaryLabelColor
        for b in [button, touchButton] {
            b.bezelStyle = .rounded; b.controlSize = .large; b.widthAnchor.constraint(equalToConstant: 320).isActive = true
        }
        touchButton.image = NSImage(systemSymbolName: "touchid", accessibilityDescription: nil)
        touchButton.imagePosition = .imageLeading
        remember.state = .on

        let header = NSStackView(views: [icon, title, sub])
        header.orientation = .vertical; header.spacing = 4; header.alignment = .centerX
        let stack = NSStackView(views: [header, hostField, userField, passField, remember, status, linkRow, touchButton, button, forgetButton])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 12
        stack.setCustomSpacing(22, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 24, right: 40)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.contentView = stack
            glass.cornerRadius = 26
            connectWindow.contentView = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
            fx.wantsLayer = true; fx.layer?.cornerRadius = 18; fx.layer?.masksToBounds = true
            stack.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(stack)
            NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
                                         stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor)])
            connectWindow.contentView = fx
        }
        connectWindow.makeKeyAndOrderFront(nil)
        refreshSaved()
    }

    private func refreshSaved() {
        let has = !hostField.stringValue.isEmpty && Keychain.exists(account)
        touchButton.isHidden = !has; forgetButton.isHidden = !has
        if has { touchButton.keyEquivalent = "\r"; button.keyEquivalent = "" } else { button.keyEquivalent = "\r" }
    }

    @objc private func touchConnect() {
        let acct = account
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Connect to your remote Mac") { ok, err in
            DispatchQueue.main.async {
                guard ok else { self.status.stringValue = "Touch ID cancelled."; return }
                guard let pw = Keychain.load(acct) else { self.status.stringValue = "Saved login not found - enter it again."; return }
                self.pendingPassword = nil
                self.startConnection(password: pw)
            }
        }
    }

    @objc private func forget() {
        Keychain.delete(account); passField.stringValue = ""; refreshSaved()
        status.stringValue = "Saved login removed."
    }

    @objc private func connect() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { status.stringValue = "Enter the remote Mac's address."; return }
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(userField.stringValue, forKey: "user")
        retries = 0; RFBClient.useZRLE = true
        UserDefaults.standard.set(userField.stringValue, forKey: "user")
        pendingPassword = remember.state == .on ? passField.stringValue : nil
        startConnection(password: passField.stringValue)
    }

    private func startConnection(password: String) {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        status.stringValue = ""; button.isEnabled = false; touchButton.isEnabled = false; button.title = "Linking…"
        setLinking("Linking to \(host)…")
        lastPassword = password
        let c = RFBClient(); c.delegate = self; client = c
        c.start(host: host, port: "5900", username: userField.stringValue, password: password)
    }

    // MARK: RFBClientDelegate

    func rfbDidConnect(width: Int, height: Int) {
        if let pw = pendingPassword, !pw.isEmpty { Keychain.save(pw, account: account) }
        pendingPassword = nil
        setLinking("Signed in - opening the screen…")
        // The connect window stays up (no black flash) until the first real picture has arrived.
        if let c = client { watch(c, since: Date()) }
    }

    /// Wait for a non-black frame, then morph the connect window into the full-screen view.
    /// Apple's server sometimes sends an all-black screen; a fresh connection usually fixes it.
    private func watch(_ c: RFBClient, since: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, c === self.client, self.viewer == nil else { return }
            if c.updates > 0 && c.nonBlackSample() > 0 { self.presentViewer(for: c); return }
            if c.updates > 0 && Date().timeIntervalSince(since) > 2.5 && self.retries < 4 {
                self.retries += 1; self.retrying = true
                RFBClient.useZRLE = self.retries < 2 // after two black tries, assume compression is the culprit
                Log.write("black screen, reconnecting (attempt \(self.retries))")
                c.stop(); return
            }
            if Date().timeIntervalSince(since) < 20 { self.watch(c, since: since) }
        }
    }

    private func presentViewer(for c: RFBClient) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let start = connectWindow.frame
        let w = ViewerWindow(contentRect: start, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.backgroundColor = .black; w.isOpaque = false; w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.alphaValue = 0
        let v = RemoteView(frame: NSRect(origin: .zero, size: start.size))
        v.autoresizingMask = [.width, .height]
        v.client = c
        v.onDisconnect = { [weak self] in self?.client?.stop() }
        w.contentView = v
        w.onDisconnect = { [weak self] in self?.client?.stop() }
        w.onCycleColour = { [weak v] in v?.cycleColour() }
        w.acceptsMouseMovedEvents = true
        v.refresh()
        w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v)
        viewer = w; view = v
        // Morph: the window grows from the connect window's frame to the whole display (camera row included).
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.55
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            w.animator().setFrame(screen.frame, display: true)
            w.animator().alphaValue = 1
            self.connectWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            w.setFrame(screen.frame, display: true)
            self.connectWindow.orderOut(nil); self.connectWindow.alphaValue = 1
            self.setLinking(nil)
            v.installOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { v.overlay.isHidden = true }
        })
    }

    func rfbDidResize(width: Int, height: Int) { view?.refresh() }
    func rfbNeedsDisplay() { view?.refresh() }

    func rfbDidDisconnect(error: String?) {
        if retrying {
            retrying = false
            client = nil
            startConnection(password: lastPassword) // connect window stays up: no flicker
            return
        }
        viewer?.orderOut(nil); viewer = nil; view = nil; client = nil
        NSApp.presentationOptions = []
        setLinking(nil)
        button.isEnabled = true; touchButton.isEnabled = true; button.title = "Connect"; passField.stringValue = ""
        refreshSaved()
        status.stringValue = error ?? ""
        connectWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
