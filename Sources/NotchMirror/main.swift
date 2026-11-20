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
        if !dumped {   // one PNG so we can check cropping without screenshots
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

    func stream(_ stream: SCStream, didStopWithError error: Error) { log("stream stopped: \(error)") }
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
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let wins = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.apple.ScreenSharing" && $0.frame.width > 600 }
            guard let win = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                log("No Screen Sharing window found. Open Screen Sharing and connect to the other Mac first."); NSApp.terminate(nil); return
            }
            await MainActor.run { self.show(for: win) }
            try await capturer.start(window: win, scale: NSScreen.main?.backingScaleFactor ?? 2)
        } catch { log("error: \(error)"); NSApp.terminate(nil) }
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
        v.layer?.contentsGravity = .resizeAspectFill    // fill the display; crop is done with contentsRect
        w.contentView = v
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w
        var cropped = false
        capturer.onFrame = { [weak self, weak v] surf, pw, ph in
            guard let self, let v else { return }
            if !cropped {
                cropped = true
                let scale = CGFloat(ph) / win.frame.height
                let topPx = self.titleBar * scale
                let contentH = CGFloat(ph) - topPx
                // Remote picture is letterboxed in the window; keep a centred region with the display's aspect ratio.
                let target = screen.frame.width / screen.frame.height
                var cw = contentH * target
                if cw > CGFloat(pw) { cw = CGFloat(pw) }
                let x0 = (CGFloat(pw) - cw) / 2
                // contentsRect is normalised with origin at bottom-left: trim the title bar off the top.
                v.layer?.contentsRect = CGRect(x: x0 / CGFloat(pw), y: 0, width: cw / CGFloat(pw), height: contentH / CGFloat(ph))
                log("crop: window \(pw)x\(ph)px, title \(topPx)px, region \(Int(cw))x\(Int(contentH))px")
            }
            v.layer?.contents = surf
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
