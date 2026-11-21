import AppKit
import ScreenCaptureKit
import CoreMedia

// NotchMirror (prototype): mirrors Apple's own Screen Sharing window across the WHOLE built-in display,
// camera row included. Apple's client does the networking, colour, speed and sound; we only show its picture.

func log(_ s: String) {
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/NotchMirror.log")
    let line = "\(Date()) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    print(s)
}

// MARK: Accessibility helpers (drive Screen Sharing's window and View menu)

func axAttr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func axTitle(_ e: AXUIElement) -> String { (axAttr(e, kAXTitleAttribute) as? String) ?? "" }
func axChildren(_ e: AXUIElement) -> [AXUIElement] { (axAttr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

/// Items of a top-level menu (e.g. "View") of the app, as (title, element).
func axMenuItems(_ app: AXUIElement, menu: String) -> [(String, AXUIElement)] {
    guard let mb = axAttr(app, kAXMenuBarAttribute) else { return [] }
    for top in axChildren(mb as! AXUIElement) where axTitle(top) == menu {
        return axChildren(top).flatMap { axChildren($0) }.map { (axTitle($0), $0) }
    }
    return []
}

/// Presses a menu item if it exists (returns false when the title isn't there, e.g. already in that state).
@discardableResult func axPressMenu(_ app: AXUIElement, menu: String, title: String) -> Bool {
    guard let item = axMenuItems(app, menu: menu).first(where: { $0.0 == title })?.1 else { return false }
    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
}

func axSet(_ w: AXUIElement, size: CGSize, position: CGPoint) {
    var sz = size, pos = position
    if let sv = AXValueCreate(.cgSize, &sz) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
    if let pv = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
}

final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { false }   // never steal keyboard focus from Screen Sharing
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
}

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "notchmirror.capture")
    var onFrame: ((IOSurface, Int, Int) -> Void)?
    private var dumped = false
    private let started = Date()

    func start(window: SCWindow, scale: CGFloat) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(window.frame.width * scale); cfg.height = Int(window.frame.height * scale)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.queueDepth = 4
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        log("capturing window '\(window.title ?? "")' \(Int(window.frame.width))x\(Int(window.frame.height)) @\(scale)x")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb),
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if !dumped && Date().timeIntervalSince(started) > 3 {   // one PNG (after things settle) to check cropping
            dumped = true
            let ci = CIImage(cvPixelBuffer: pb)
            if let cg = CIContext().createCGImage(ci, from: ci.extent) {
                let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/NotchMirror-frame.png")
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                log("first frame \(w)x\(h) saved")
            }
        }
        DispatchQueue.main.async { self.onFrame?(surf, w, h) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped: \(error)")
        DispatchQueue.main.async { NSApp.terminate(nil) }   // Screen Sharing closed: give the display back
    }
}

final class App: NSObject, NSApplicationDelegate {
    var window: MirrorWindow?
    let capturer = Capturer()
    // Points trimmed from the top of the Screen Sharing window (its title bar); override with NOTCH_TITLEBAR.
    let titleBar = CGFloat(Double(ProcessInfo.processInfo.environment["NOTCH_TITLEBAR"] ?? "") ?? 32)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            log("Screen Recording permission needed: System Settings > Privacy & Security > Screen & System Audio Recording, enable NotchMirror, then reopen it.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        }
        Task { await self.run() }
    }

    func run() async {
        do {
            // 1. Accessibility lets us set Screen Sharing up so its picture is exactly the other Mac's screen.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(opts) else {
                log("Accessibility permission needed: System Settings > Privacy & Security > Accessibility (Device Control...), enable NotchMirror, then reopen it.")
                await MainActor.run { NSApp.terminate(nil) }; return
            }
            guard let ss = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSharing").first else {
                log("Screen Sharing isn't running. Open it and connect to the other Mac first."); await MainActor.run { NSApp.terminate(nil) }; return
            }
            let axApp = AXUIElementCreateApplication(ss.processIdentifier)
            let items = axMenuItems(axApp, menu: "View").map { $0.0 }
            log("View menu: \(items.filter { $0.contains("Scaling") || $0.contains("Toolbar") || $0.contains("Full Screen") })")
            if items.contains("Exit Full Screen") { axPressMenu(axApp, menu: "View", title: "Exit Full Screen"); try await Task.sleep(nanoseconds: 1_200_000_000) }
            axPressMenu(axApp, menu: "View", title: "Turn Scaling On")   // only present when scaling is off
            axPressMenu(axApp, menu: "View", title: "Hide Toolbar")
            try await Task.sleep(nanoseconds: 500_000_000)

            // 2. Size the window so its picture area has the other Mac's aspect ratio (no bars, nothing cropped).
            let aspect = CGFloat(Double(ProcessInfo.processInfo.environment["NOTCH_ASPECT"] ?? "") ?? (3456.0 / 2234.0))
            let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
            let menuH = screen.frame.maxY - screen.visibleFrame.maxY            // menu bar height at the top
            let availH = screen.visibleFrame.height - titleBar   // visibleFrame excludes the Dock, which windows can't cover
            var cw = availH * aspect, ch = availH
            if cw > screen.frame.width { cw = screen.frame.width; ch = cw / aspect }
            if let wins = axAttr(axApp, kAXWindowsAttribute) as? [AXUIElement],
               let w = wins.first(where: { axTitle($0) != "All Connections" && !axTitle($0).isEmpty }) ?? wins.first {
                axSet(w, size: CGSize(width: cw, height: ch + titleBar), position: CGPoint(x: (screen.frame.width - cw) / 2, y: max(menuH, screen.safeAreaInsets.top)))
                log("sized Screen Sharing window to \(Int(cw))x\(Int(ch + titleBar)) pt (aspect \(String(format: "%.3f", aspect)))")
            }
            try await Task.sleep(nanoseconds: 800_000_000)

            // 3. Capture it.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let wins = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.ScreenSharing" && $0.frame.width > 600 }
            guard let win = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                log("No Screen Sharing window found. Open Screen Sharing and connect to the other Mac first."); await MainActor.run { NSApp.terminate(nil) }; return
            }
            await MainActor.run { self.show(for: win) }
            try await capturer.start(window: win, scale: NSScreen.main?.backingScaleFactor ?? 2)
        } catch { log("error: \(error)"); await MainActor.run { NSApp.terminate(nil) } }
    }

    @MainActor func show(for win: SCWindow) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let w = MirrorWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.backgroundColor = .black; w.isOpaque = true; w.hasShadow = false
        w.ignoresMouseEvents = true                     // clicks fall through to Screen Sharing underneath
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.contentsGravity = .resize              // fill the display; crop is done with contentsRect
        w.contentView = v
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w
        installExit(on: v)
        var cropped = false
        capturer.onFrame = { [weak self, weak v] surf, pw, ph in
            guard let self, let v else { return }
            if !cropped {
                cropped = true
                let scale = CGFloat(ph) / win.frame.height
                // Full-screen Screen Sharing has no title bar; a normal window has ~32pt of it.
                let isFull = win.frame.height >= screen.frame.height - screen.safeAreaInsets.top - 4
                let topPx = (isFull ? 0 : self.titleBar) * scale
                let contentH = CGFloat(ph) - topPx
                // Find the real picture: black side bars (if any) are trimmed by scanning for non-black columns.
                var left = 0, right = pw - 1
                IOSurfaceLock(surf, .readOnly, nil)
                let base = IOSurfaceGetBaseAddress(surf).assumingMemoryBound(to: UInt8.self)
                let bpr = IOSurfaceGetBytesPerRow(surf)
                func colHasContent(_ x: Int) -> Bool {
                    var y = Int(topPx) + 4
                    while y < ph - 4 { let o = y * bpr + x * 4; if base[o] | base[o + 1] | base[o + 2] > 6 { return true }; y += 23 }
                    return false
                }
                while left < pw - 1 && !colHasContent(left) { left += 1 }
                while right > left && !colHasContent(right) { right -= 1 }
                IOSurfaceUnlock(surf, .readOnly, nil)
                let cw = CGFloat(right - left + 1)
                v.layer?.contentsRect = CGRect(x: CGFloat(left) / CGFloat(pw), y: 0, width: cw / CGFloat(pw), height: contentH / CGFloat(ph))
                log("crop: window \(pw)x\(ph)px, title \(topPx)px, picture x \(left)...\(right), height \(Int(contentH))px")
            }
            v.layer?.contents = surf
        }
    }
}

extension App {
    /// Safety exits (the mirror ignores the mouse and can't take the keyboard, so it needs its own way out):
    /// 1. hold the pointer in the bottom-left corner for ~1.2s;  2. NOTCH_TIMEOUT=<seconds> for test runs;
    /// 3. closing the Screen Sharing connection ends it automatically.
    func installExit(on v: NSView) {
        let hint = NSTextField(labelWithString: "Hold the pointer in the bottom-left corner to exit")
        hint.textColor = .white; hint.backgroundColor = NSColor.black.withAlphaComponent(0.7); hint.drawsBackground = true
        hint.font = .systemFont(ofSize: 15, weight: .medium); hint.sizeToFit()
        hint.frame.origin = NSPoint(x: 24, y: 40)
        v.addSubview(hint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { hint.removeFromSuperview() }

        var since: Date?
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            let p = NSEvent.mouseLocation
            if p.x < 10 && p.y < 10 {
                if since == nil {
                    since = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        let q = NSEvent.mouseLocation
                        if let s = since, q.x < 10, q.y < 10, Date().timeIntervalSince(s) >= 1.15 { log("exit: corner"); NSApp.terminate(nil) }
                    }
                }
            } else { since = nil }
        }
        if let t = ProcessInfo.processInfo.environment["NOTCH_TIMEOUT"], let sec = Double(t) {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { log("exit: timeout"); NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
