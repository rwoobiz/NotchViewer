import Foundation

/// Minimal unsigned big integer, just enough for the Diffie-Hellman step of
/// Apple Remote Desktop authentication (1024-bit modular exponentiation).
struct BigUInt {
    var w: [UInt32] // little-endian words, trimmed

    init(_ words: [UInt32]) { w = words; trim() }
    init(_ v: UInt32) { self.init([v]) }

    init(bytes: [UInt8]) { // big-endian
        var words = [UInt32](repeating: 0, count: (bytes.count + 3) / 4)
        for (i, b) in bytes.reversed().enumerated() { words[i / 4] |= UInt32(b) << UInt32((i % 4) * 8) }
        self.init(words)
    }

    mutating func trim() { while let l = w.last, l == 0 { w.removeLast() } }

    func bytes(count n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let wi = i / 4
            if wi < w.count { out[n - 1 - i] = UInt8((w[wi] >> UInt32((i % 4) * 8)) & 0xff) }
        }
        return out
    }

    var bitCount: Int {
        guard let l = w.last else { return 0 }
        return (w.count - 1) * 32 + (32 - l.leadingZeroBitCount)
    }

    func bit(_ i: Int) -> Bool {
        let wi = i / 32
        return wi < w.count && (w[wi] >> UInt32(i % 32)) & 1 == 1
    }

    static func cmp(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.w.count != b.w.count { return a.w.count < b.w.count ? -1 : 1 }
        for i in stride(from: a.w.count - 1, through: 0, by: -1) where a.w[i] != b.w[i] {
            return a.w[i] < b.w[i] ? -1 : 1
        }
        return 0
    }

    static func sub(_ a: BigUInt, _ b: BigUInt) -> BigUInt { // requires a >= b
        var r = a.w
        var borrow: Int64 = 0
        for i in 0..<r.count {
            var d = Int64(r[i]) - borrow - (i < b.w.count ? Int64(b.w[i]) : 0)
            if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
            r[i] = UInt32(d)
        }
        return BigUInt(r)
    }

    static func mul(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        if a.w.isEmpty || b.w.isEmpty { return BigUInt([]) }
        var r = [UInt32](repeating: 0, count: a.w.count + b.w.count)
        for i in 0..<a.w.count {
            var carry: UInt64 = 0
            for j in 0..<b.w.count {
                let t = UInt64(a.w[i]) * UInt64(b.w[j]) + UInt64(r[i + j]) + carry
                r[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            r[i + b.w.count] = UInt32(carry)
        }
        return BigUInt(r)
    }

    func mod(_ m: BigUInt) -> BigUInt {
        var r = BigUInt([])
        for i in stride(from: bitCount - 1, through: 0, by: -1) {
            var carry: UInt32 = bit(i) ? 1 : 0
            for k in 0..<r.w.count {
                let nc = r.w[k] >> 31
                r.w[k] = (r.w[k] << 1) | carry
                carry = nc
            }
            if carry != 0 { r.w.append(carry) }
            if BigUInt.cmp(r, m) >= 0 { r = BigUInt.sub(r, m) }
        }
        return r
    }

    static func slowModPow(_ base: BigUInt, _ exp: BigUInt, _ m: BigUInt) -> BigUInt {
        var result = BigUInt(1)
        var b = base.mod(m)
        for i in 0..<exp.bitCount {
            if exp.bit(i) { result = mul(result, b).mod(m) }
            b = mul(b, b).mod(m)
        }
        return result
    }

    /// Fast path (Montgomery multiplication) for odd moduli; the Diffie-Hellman prime is odd.
    static func modPow(_ base: BigUInt, _ exp: BigUInt, _ m: BigUInt) -> BigUInt {
        let n = m.w.count
        guard n >= 2, m.w[0] & 1 == 1 else { return slowModPow(base, exp, m) }
        let mw = m.w
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- mw[0] &* inv) }
        let n0 = 0 &- inv

        func geq(_ a: [UInt32]) -> Bool { // a (n words) >= m
            for i in stride(from: n - 1, through: 0, by: -1) where a[i] != mw[i] { return a[i] > mw[i] }
            return true
        }
        func subM(_ a: inout [UInt32]) {
            var borrow: Int64 = 0
            for i in 0..<n {
                var d = Int64(a[i]) - Int64(mw[i]) - borrow
                if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
                a[i] = UInt32(d)
            }
        }
        func dbl(_ a: inout [UInt32]) {
            var carry: UInt32 = 0
            for i in 0..<n { let nc = a[i] >> 31; a[i] = (a[i] << 1) | carry; carry = nc }
            if carry != 0 || geq(a) { subM(&a) }
        }
        func mont(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var t = [UInt32](repeating: 0, count: n + 2)
            for i in 0..<n {
                var c: UInt64 = 0
                for j in 0..<n {
                    let s = UInt64(t[j]) + UInt64(a[j]) * UInt64(b[i]) + c
                    t[j] = UInt32(truncatingIfNeeded: s); c = s >> 32
                }
                var s = UInt64(t[n]) + c
                t[n] = UInt32(truncatingIfNeeded: s); t[n + 1] = UInt32(truncatingIfNeeded: s >> 32)
                let q = t[0] &* n0
                s = UInt64(t[0]) + UInt64(q) * UInt64(mw[0]); c = s >> 32
                for j in 1..<n {
                    s = UInt64(t[j]) + UInt64(q) * UInt64(mw[j]) + c
                    t[j - 1] = UInt32(truncatingIfNeeded: s); c = s >> 32
                }
                s = UInt64(t[n]) + c
                t[n - 1] = UInt32(truncatingIfNeeded: s)
                t[n] = t[n + 1] + UInt32(truncatingIfNeeded: s >> 32)
            }
            var res = Array(t[0..<n])
            if t[n] != 0 || geq(res) { subM(&res) }
            return res
        }

        var r1 = [UInt32](repeating: 0, count: n); r1[0] = 1
        for _ in 0..<(32 * n) { dbl(&r1) }           // R mod m
        var r2 = r1
        for _ in 0..<(32 * n) { dbl(&r2) }           // R^2 mod m
        var b = base.mod(m).w; b += [UInt32](repeating: 0, count: n - b.count)
        let bm = mont(b, r2)                          // base in Montgomery form
        var result = r1                               // 1 in Montgomery form
        for i in stride(from: exp.bitCount - 1, through: 0, by: -1) {
            result = mont(result, result)
            if exp.bit(i) { result = mont(result, bm) }
        }
        var one = [UInt32](repeating: 0, count: n); one[0] = 1
        return BigUInt(mont(result, one))
    }
}
