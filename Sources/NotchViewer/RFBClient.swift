import Foundation
import CoreGraphics
import CryptoKit
import CommonCrypto
import CZlib
import IOSurface

struct RFBError: Error { let message: String; init(_ m: String) { message = m } }

protocol RFBClientDelegate: AnyObject {
    func rfbDidConnect(width: Int, height: Int)
    func rfbDidResize(width: Int, height: Int)
    func rfbNeedsDisplay()
    func rfbDidDisconnect(error: String?)
}

/// Small RFB (VNC) client: ARD (type 30) and VNC (type 2) auth; ZRLE, Raw, CopyRect, DesktopSize.
final class RFBClient {
    /// Compressed updates are much faster; falls back to Raw if a connection keeps coming up black.
    static var useZRLE = true
    /// Colour handling: default passes the remote's pixel values straight to this display (both Macs are wide-gamut).
    /// `defaults write dev.notchviewer.app colorSpace p3` (or `srgb`) tags the picture explicitly instead.
    static func taggedColorSpace() -> CGColorSpace? {
        switch UserDefaults.standard.string(forKey: "colorSpace") {
        case "p3": return CGColorSpace(name: CGColorSpace.displayP3)
        case "srgb": return CGColorSpace(name: CGColorSpace.sRGB)
        default: return nil
        }
    }
    weak var delegate: RFBClientDelegate?
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let fbLock = NSLock()
    private(set) var width = 0
    private(set) var height = 0
    private var fb: UnsafeMutablePointer<UInt8>? // BGRA, lives inside the IOSurface below
    private var stride = 0
    private var surface: IOSurfaceRef?
    private var surfaceLocked = false
    /// The remote screen as a GPU-shared surface: the layer shows it directly, with no per-frame image copy.
    var displaySurface: IOSurfaceRef? { surface }
    private var stopped = false
    private(set) var updates = 0
    private(set) var rects = 0
    private(set) var lastEncoding: Int32 = 0
    private(set) var serverName = ""
    private var refreshScheduled = false
    private var zstream = z_stream()
    private var zReady = false

    deinit { unlockSurface(); if zReady { inflateEnd(&zstream) } }

    // MARK: lifecycle

    func start(host: String, port: String, username: String, password: String) {
        Thread.detachNewThread { [self] in
            do {
                try openSocket(host: host, port: port)
                try handshake(username: username, password: password)
                delegate.map { d in DispatchQueue.main.async { d.rfbDidConnect(width: self.width, height: self.height) } }
                // Apple's server answers the first request with a black frame, so ask for full refreshes a few times.
                Thread.detachNewThread { [self] in
                    for d in [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0] { Thread.sleep(forTimeInterval: d); if stopped { return }; requestUpdate(incremental: false) }
                }
                try receiveLoop()
            } catch {
                let msg = (error as? RFBError)?.message ?? "\(error)"
                finish(error: stopped ? nil : msg)
            }
        }
    }

    func stop() {
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private func finish(error: String?) {
        if fd >= 0 { close(fd); fd = -1 }
        DispatchQueue.main.async { self.delegate?.rfbDidDisconnect(error: error) }
    }

    // MARK: socket helpers

    /// Tries each comma-separated address in order (for example "192.168.1.20, 100.64.0.5": home Wi-Fi, then Tailscale)
    /// and uses the first one that answers. A 100.x address is a Tailscale one: if it doesn't answer we start the
    /// Tailscale app and try once more, so being away from home "just works".
    private func openSocket(host: String, port: String) throws {
        let candidates = host.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { throw RFBError("Enter the remote Mac's address") }
        let seconds = candidates.count > 1 ? 3 : 10
        for cand in candidates {
            // At home: the home address is on one of this Mac's networks. Away: it isn't, so skip it
            // immediately instead of waiting (or reaching some other network's device) and go to Tailscale.
            if candidates.count > 1 && !RFBClient.isOnLocalNetwork(cand) { Log.write("skipping \(cand): not on a network this Mac is on"); continue }
            let isTailscale = cand.hasPrefix("100.")
            for attempt in 0..<(isTailscale ? 2 : 1) {
                if attempt == 1 {
                    Log.write("starting Tailscale and retrying \(cand)")
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-g", "-a", "Tailscale"]
                    try? p.run(); p.waitUntilExit()
                    Thread.sleep(forTimeInterval: 5)
                }
                if tryConnect(cand, port: port, seconds: attempt == 1 ? 6 : seconds) { return }
            }
            Log.write("no answer from \(cand)")
        }
        throw RFBError("Could not reach \(host) - is the other Mac awake and online (Wi-Fi or Tailscale)?")
    }

    /// True unless `cand` is a private LAN address (192.168.x.x, 10.x, 172.16-31.x) that this Mac has no interface for.
    static func isPrivateLAN(_ cand: String) -> Bool {
        let p = cand.split(separator: ".").compactMap { UInt32($0) }
        guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
    }

    static func isOnLocalNetwork(_ cand: String) -> Bool {
        let parts = cand.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return true }   // a name: just try it
        let isPrivate = parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
        guard isPrivate else { return true }
        let c = parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return true }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let i = p {
            if let a = i.pointee.ifa_addr, let m = i.pointee.ifa_netmask, a.pointee.sa_family == UInt8(AF_INET),
               i.pointee.ifa_flags & UInt32(IFF_UP) != 0 {
                let ip = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if ip >> 24 != 127 && ip & mask == c & mask { return true }
            }
            p = i.pointee.ifa_next
        }
        return false
    }

    /// Which route applies right now: the first listed address this Mac can reach directly (home network),
    /// otherwise the first non-LAN one (Tailscale or a public name).
    static func route(for cands: [String]) -> (kind: String, addr: String)? {
        for c in cands {
            if isPrivateLAN(c) {
                if isOnLocalNetwork(c) { return ("Home Wi-Fi", c) }
            } else {
                return (c.hasPrefix("100.") ? "Tailscale" : "Direct", c)
            }
        }
        return nil
    }

    /// Quick "is the other Mac answering?" check.
    static func probe(_ host: String, port: String = "5900", seconds: Int = 2) -> Bool {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(res) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                let ok = connectWithTimeout(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen, seconds: seconds)
                close(s)
                if ok { return true }
            }
            p = ai.pointee.ai_next
        }
        return false
    }

    private func tryConnect(_ cand: String, port: String, seconds: Int) -> Bool {
        var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(cand, port, &hints, &res) == 0, let first = res else { Log.write("cannot resolve \(cand)"); return false }
        defer { freeaddrinfo(res) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s >= 0 {
                if RFBClient.connectWithTimeout(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen, seconds: seconds) {
                    var one: Int32 = 1
                    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    fd = s
                    Log.write("connected via \(cand)")
                    return true
                }
                close(s)
            }
            p = ai.pointee.ai_next
        }
        return false
    }

    static func connectWithTimeout(_ s: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t, seconds: Int) -> Bool {
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        var r = Darwin.connect(s, addr, len)
        if r != 0 && errno == EINPROGRESS {
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, Int32(seconds * 1000)) > 0 {
                var err: Int32 = 0; var l = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &l)
                r = err == 0 ? 0 : -1
            } else { r = -1 }
        }
        _ = fcntl(s, F_SETFL, flags)
        return r == 0
    }

    private func read(_ n: Int) throws -> [UInt8] {
        guard n > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        try buf.withUnsafeMutableBytes { try readInto($0.baseAddress!, n) }
        return buf
    }

    private func readInto(_ ptr: UnsafeMutableRawPointer, _ n: Int) throws {
        var got = 0
        while got < n {
            let r = recv(fd, ptr + got, n - got, 0)
            if r <= 0 { throw RFBError("Connection closed") }
            got += r
        }
    }

    private func send(_ bytes: [UInt8]) {
        writeLock.lock(); defer { writeLock.unlock() }
        guard fd >= 0 else { return }
        var sent = 0
        while sent < bytes.count {
            let r = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if r <= 0 { return }
            sent += r
        }
    }

    private func u16(_ b: [UInt8], _ o: Int = 0) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
    private func u32(_ b: [UInt8], _ o: Int = 0) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    // MARK: handshake

    private func handshake(username: String, password: String) throws {
        let ver = String(decoding: try read(12), as: UTF8.self)
        guard ver.hasPrefix("RFB ") else { throw RFBError("Not a VNC server (\(ver.trimmingCharacters(in: .whitespacesAndNewlines)))") }
        send(Array((ver.hasPrefix("RFB 003.889") ? "RFB 003.889\n" : "RFB 003.008\n").utf8))

        let count = Int(try read(1)[0])
        if count == 0 {
            let len = Int(u32(try read(4)))
            throw RFBError("Server refused: " + String(decoding: try read(len), as: UTF8.self))
        }
        let types = try read(count)
        Log.write("security types offered: \(types)")
        if types.contains(2) && username.isEmpty {
            send([2]); try authVNC(password: password)
        } else if types.contains(30) {
            send([30]); try authARD(username: username, password: password)
        } else if types.contains(2) {
            send([2]); try authVNC(password: password)
        } else if types.contains(1) {
            send([1])
        } else {
            throw RFBError("No supported security type (server offers \(types))")
        }
        let result = u32(try read(4))
        Log.write("auth result \(result)")
        if result != 0 {
            throw RFBError("Authentication failed - check the username and password of the remote Mac")
        }

        send([1]) // ClientInit: shared
        let si = try read(24)
        width = u16(si, 0); height = u16(si, 2)
        serverName = String(decoding: try read(Int(u32(si, 20))), as: UTF8.self)
        Log.write("ServerInit \(width)x\(height) '\(serverName)'")
        allocate(width, height)

        // 32bpp little-endian BGRA
        var pf: [UInt8] = [0, 0, 0, 0, 32, 24, 0, 1]
        pf += be16(255) + be16(255) + be16(255) + [16, 8, 0, 0, 0, 0]
        send(pf)
        // Preference order: ZRLE (compressed), CopyRect, Raw, then DesktopSize pseudo-encoding.
        if RFBClient.useZRLE {
            send([2, 0] + be16(4) + be32(16) + be32(1) + be32(0) + be32(UInt32(bitPattern: Int32(-223))))
        } else {
            send([2, 0] + be16(3) + be32(1) + be32(0) + be32(UInt32(bitPattern: Int32(-223))))
        }
        Log.write("compression (ZRLE) \(RFBClient.useZRLE ? "on" : "off")")
        requestUpdate(incremental: false)
    }

    private func allocate(_ w: Int, _ h: Int) {
        fbLock.lock(); defer { fbLock.unlock() }
        width = w; height = h
        unlockSurface()
        let props: [CFString: Any] = [kIOSurfaceWidth: w, kIOSurfaceHeight: h, kIOSurfaceBytesPerElement: 4,
                                      kIOSurfacePixelFormat: 0x42475241 as UInt32] // 'BGRA'
        surface = IOSurfaceCreate(props as CFDictionary)
        if let s = surface {
            stride = IOSurfaceGetBytesPerRow(s)
            if let cs = RFBClient.taggedColorSpace(), let plist = cs.copyPropertyList() { IOSurfaceSetValue(s, kIOSurfaceColorSpace, plist) }
            fb = IOSurfaceGetBaseAddress(s).assumingMemoryBound(to: UInt8.self)
            lockSurface(); memset(fb!, 0, stride * h); unlockSurface()
        }
    }

    private func lockSurface() { if let s = surface, !surfaceLocked { IOSurfaceLock(s, [], nil); surfaceLocked = true } }
    private func unlockSurface() { if let s = surface, surfaceLocked { IOSurfaceUnlock(s, [], nil); surfaceLocked = false } }

    private func authVNC(password: String) throws {
        let challenge = try read(16)
        var key = [UInt8](repeating: 0, count: 8)
        for (i, b) in password.utf8.prefix(8).enumerated() {
            var r: UInt8 = 0
            for bit in 0..<8 where b & (1 << UInt8(bit)) != 0 { r |= 1 << UInt8(7 - bit) }
            key[i] = r
        }
        var out = [UInt8](repeating: 0, count: 16 + kCCBlockSizeDES)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, 8, nil, challenge, 16, &out, out.count, &moved)
        guard status == kCCSuccess else { throw RFBError("VNC password encryption failed") }
        send(Array(out.prefix(16)))
    }

    private func authARD(username: String, password: String) throws {
        let head = try read(4)
        let generator = u16(head, 0), keyLen = u16(head, 2)
        let prime = BigUInt(bytes: try read(keyLen))
        let serverPub = BigUInt(bytes: try read(keyLen))

        var priv = [UInt8](repeating: 0, count: keyLen)
        for i in 0..<keyLen { priv[i] = UInt8.random(in: 0...255) }
        let privN = BigUInt(bytes: priv)
        let pub = BigUInt.modPow(BigUInt(UInt32(generator)), privN, prime).bytes(count: keyLen)
        let shared = BigUInt.modPow(serverPub, privN, prime).bytes(count: keyLen)
        let key = Array(Insecure.MD5.hash(data: shared))

        var creds = [UInt8](repeating: 0, count: 128)
        for i in 0..<128 { creds[i] = UInt8.random(in: 0...255) }
        func put(_ s: String, at o: Int) {
            let b = Array(s.utf8.prefix(63))
            for (i, c) in b.enumerated() { creds[o + i] = c }
            creds[o + b.count] = 0
        }
        put(username, at: 0); put(password, at: 64)

        var enc = [UInt8](repeating: 0, count: 128 + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, 16, nil, creds, 128, &enc, enc.count, &moved)
        guard status == kCCSuccess else { throw RFBError("ARD encryption failed") }
        send(Array(enc.prefix(128)) + pub)
    }

    // MARK: receive loop

    private func requestUpdate(incremental: Bool) {
        send([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(width) + be16(height))
    }

    private func receiveLoop() throws {
        while !stopped {
            let type = try read(1)[0]
            switch type {
            case 0:
                let h = try read(3)
                let n = u16(h, 1)
                var resized = false
                lockSurface()
                for _ in 0..<n {
                    let r = try read(12)
                    let x = u16(r, 0), y = u16(r, 2), w = u16(r, 4), hgt = u16(r, 6)
                    let enc = Int32(bitPattern: u32(r, 8))
                    rects += 1
                    if enc != lastEncoding { Log.write("encoding in use: \(enc)") }
                    lastEncoding = enc
                    switch enc {
                    case 0: try readRaw(x: x, y: y, w: w, h: hgt)
                    case 1: try readCopyRect(x: x, y: y, w: w, h: hgt)
                    case 16: try readZRLE(x: x, y: y, w: w, h: hgt)
                    case -223:
                        allocate(w, hgt)
                        lockSurface()
                        resized = true
                    default: throw RFBError("Unsupported encoding \(enc)")
                    }
                }
                unlockSurface()
                updates += 1
                if resized {
                    DispatchQueue.main.async { self.delegate?.rfbDidResize(width: self.width, height: self.height) }
                    requestUpdate(incremental: false)
                } else {
                    requestUpdate(incremental: true)
                }
                scheduleRefresh()
            case 1:
                let h = try read(5); _ = try read(u16(h, 3) * 6)
            case 2: break
            case 3:
                let h = try read(7); _ = try read(Int(u32(h, 3)))
            default:
                throw RFBError("Unknown server message \(type)")
            }
        }
    }

    /// Coalesce redraws to at most ~60 per second.
    private func scheduleRefresh() {
        fbLock.lock()
        if refreshScheduled { fbLock.unlock(); return }
        refreshScheduled = true
        fbLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self else { return }
            self.fbLock.lock(); self.refreshScheduled = false; self.fbLock.unlock()
            self.delegate?.rfbNeedsDisplay()
        }
    }

    // MARK: encodings

    private func readRaw(x: Int, y: Int, w: Int, h: Int) throws {
        guard let fb, x + w <= width, y + h <= height else { _ = try read(w * h * 4); return }
        for row in 0..<h {
            let rowPtr = fb + (y + row) * stride + x * 4
            try readInto(rowPtr, w * 4)
            // The server's 4th byte is padding (0); the GPU surface reads it as alpha, so force opaque.
            let px = UnsafeMutableRawPointer(rowPtr).assumingMemoryBound(to: UInt32.self)
            for i in 0..<w { px[i] |= 0xff00_0000 }
        }
    }

    private func readCopyRect(x: Int, y: Int, w: Int, h: Int) throws {
        let s = try read(4)
        let sx = u16(s, 0), sy = u16(s, 2)
        fbLock.lock(); defer { fbLock.unlock() }
        guard let fb, x + w <= width, y + h <= height, sx + w <= width, sy + h <= height else { return }
        var tmp = [UInt8](repeating: 0, count: w * h * 4)
        tmp.withUnsafeMutableBytes { t in
            for row in 0..<h { memcpy(t.baseAddress! + row * w * 4, fb + (sy + row) * stride + sx * 4, w * 4) }
            for row in 0..<h { memcpy(fb + (y + row) * stride + x * 4, t.baseAddress! + row * w * 4, w * 4) }
        }
    }

    private func inflateChunk(_ input: [UInt8]) throws -> [UInt8] {
        if !zReady {
            guard inflateInit_(&zstream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw RFBError("zlib init failed") }
            zReady = true
        }
        var out = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1 << 18)
        var input = input
        try input.withUnsafeMutableBufferPointer { inp in
            zstream.next_in = inp.baseAddress
            zstream.avail_in = UInt32(inp.count)
            while true {
                var produced = 0
                var status: Int32 = 0
                chunk.withUnsafeMutableBufferPointer { c in
                    zstream.next_out = c.baseAddress
                    zstream.avail_out = UInt32(c.count)
                    status = inflate(&zstream, Z_SYNC_FLUSH)
                    produced = c.count - Int(zstream.avail_out)
                }
                out += chunk[0..<produced]
                if status != Z_OK && status != Z_BUF_ERROR && status != Z_STREAM_END { throw RFBError("ZRLE inflate error \(status)") }
                if zstream.avail_in == 0 && produced < chunk.count { break }
                if status == Z_STREAM_END { break }
            }
        }
        return out
    }

    private func readZRLE(x: Int, y: Int, w: Int, h: Int) throws {
        let len = Int(u32(try read(4)))
        let data = try inflateChunk(try read(len))
        fbLock.lock(); defer { fbLock.unlock() }
        guard let fb, x + w <= width, y + h <= height else { throw RFBError("ZRLE rect out of bounds") }
        try data.withUnsafeBufferPointer { d in
            var pos = 0
            func byte() throws -> Int { guard pos < d.count else { throw RFBError("ZRLE data truncated") }; defer { pos += 1 }; return Int(d[pos]) }
            func cpixel() throws -> UInt32 { // 3 bytes: B, G, R (little-endian), alpha forced opaque
                guard pos + 3 <= d.count else { throw RFBError("ZRLE data truncated") }
                defer { pos += 3 }
                return UInt32(d[pos]) | UInt32(d[pos + 1]) << 8 | UInt32(d[pos + 2]) << 16 | 0xff00_0000
            }
            let px = UnsafeMutableRawPointer(fb).assumingMemoryBound(to: UInt32.self)
            var ty = 0
            while ty < h {
                let th = min(64, h - ty)
                var tx = 0
                while tx < w {
                    let tw = min(64, w - tx)
                    let sub = try byte()
                    let rle = sub & 0x80 != 0
                    let palSize = sub & 0x7f
                    var palette = [UInt32]()
                    if palSize > 0 && !(rle && palSize == 0) { for _ in 0..<palSize { palette.append(try cpixel()) } }
                    @inline(__always) func put(_ i: Int, _ v: UInt32) {
                        px[(y + ty + i / tw) * (stride / 4) + x + tx + i % tw] = v
                    }
                    if !rle {
                        if palSize == 0 {
                            for i in 0..<(tw * th) { put(i, try cpixel()) }
                        } else if palSize == 1 {
                            for i in 0..<(tw * th) { put(i, palette[0]) }
                        } else {
                            let bits = palSize <= 2 ? 1 : (palSize <= 4 ? 2 : 4)
                            for row in 0..<th {
                                var cur = 0, left = 0
                                for col in 0..<tw {
                                    if left == 0 { cur = try byte(); left = 8 }
                                    left -= bits
                                    let idx = (cur >> left) & ((1 << bits) - 1)
                                    guard idx < palette.count else { throw RFBError("ZRLE bad palette index") }
                                    put(row * tw + col, palette[idx])
                                }
                            }
                        }
                    } else {
                        var i = 0
                        let total = tw * th
                        while i < total {
                            var color: UInt32
                            var run = 1
                            if palSize == 0 {
                                color = try cpixel()
                                var b = try byte(); run += b
                                while b == 255 { b = try byte(); run += b }
                            } else {
                                let idx = try byte()
                                guard (idx & 0x7f) < palette.count else { throw RFBError("ZRLE bad palette index") }
                                color = palette[idx & 0x7f]
                                if idx & 0x80 != 0 {
                                    var b = try byte(); run += b
                                    while b == 255 { b = try byte(); run += b }
                                }
                            }
                            for _ in 0..<run where i < total { put(i, color); i += 1 }
                        }
                    }
                    tx += 64
                }
                ty += 64
            }
        }
    }

    // MARK: drawing + input

    /// Image copy of the framebuffer (the approach that is known to display correctly).
    func makeImage() -> CGImage? {
        guard let fb, width > 0, height > 0 else { return nil }
        let w = width, h = height, bpr = stride
        let data = Data(bytes: fb, count: bpr * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: RFBClient.taggedColorSpace() ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func nonBlackSample() -> Int {
        guard let fb else { return 0 }
        var n = 0, yy = 0
        while yy < height {
            var xx = 0
            while xx < width { let o = yy * stride + xx * 4; if fb[o] | fb[o + 1] | fb[o + 2] != 0 { n += 1 }; xx += 97 }
            yy += 37
        }
        return n
    }

    func sendKey(_ keysym: UInt32, down: Bool) { send([4, down ? 1 : 0, 0, 0] + be32(keysym)) }
    func sendPointer(x: Int, y: Int, buttons: Int) {
        send([5, UInt8(buttons & 0xff)] + be16(max(0, min(width - 1, x))) + be16(max(0, min(height - 1, y))))
    }
}
