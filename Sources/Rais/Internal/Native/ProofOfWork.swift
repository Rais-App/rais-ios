import CommonCrypto
import Foundation

/// The checkout's robot check, done by the phone instead of the payer.
///
/// The hosted page shows a checkbox (Cap, trycap.dev) that makes the browser solve a small proof of work before a card may be submitted. It is
/// a cost per attempt, not a question to a person, so a native screen pays the same cost silently: it asks for the same challenge, finds the
/// same numbers and redeems them. The server's rule is untouched and the payer sees nothing.
///
/// A challenge is `count` puzzles derived from its token. Puzzle `n` (from 1) has a salt, `prng(token + n, size)`, and a target,
/// `prng(token + n + "d", difficulty)`: the answer is the smallest number whose decimal text, appended to the salt, has a SHA-256 that starts
/// with the target (in hex).
enum ProofOfWork {
    /// The 32-bit FNV-1a hash that seeds the generator, character by character.
    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for scalar in text.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return hash
    }

    /// Cap's xorshift generator: `length` hex digits that depend only on `seed`.
    static func prng(_ seed: String, length: Int) -> String {
        var state = fnv1a(seed)
        var out = ""
        while out.count < length {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            out += String(format: "%08x", state)
        }
        return String(out.prefix(length))
    }

    /// The answers of a whole challenge, in order. Runs on every core; call it off the main thread. `nil` when a puzzle has no answer within
    /// the numbers the server accepts, which does not happen with a genuine challenge.
    static func solve(token: String, count: Int, size: Int, difficulty: Int) -> [Int]? {
        guard count > 0, count <= 256, size > 0, size <= 128, difficulty > 0, difficulty <= 8 else { return nil }
        let answers = UnsafeMutablePointer<Int>.allocate(capacity: count)
        answers.initialize(repeating: -1, count: count)
        defer { answers.deallocate() }
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let salt = prng("\(token)\(index + 1)", length: size)
            let target = prng("\(token)\(index + 1)d", length: difficulty)
            answers[index] = solveOne(salt: salt, target: target) ?? -1
        }
        let all = Array(UnsafeBufferPointer(start: answers, count: count))
        return all.contains(-1) ? nil : all
    }

    static func solveOne(salt: String, target: String, limit: Int = 200_000_000) -> Int? {
        let nibbles = target.utf8.compactMap { byte -> UInt8? in
            switch byte {
            case 48...57: return byte - 48
            case 97...102: return byte - 87
            default: return nil
            }
        }
        guard nibbles.count == target.utf8.count else { return nil }
        let prefix = Array(salt.utf8)
        var message = [UInt8](repeating: 0, count: prefix.count + 20)
        message.replaceSubrange(0..<prefix.count, with: prefix)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        var digits = [UInt8](repeating: 0, count: 20)

        return message.withUnsafeMutableBufferPointer { text -> Int? in
            digest.withUnsafeMutableBufferPointer { hash -> Int? in
                var nonce = 0
                while nonce < limit {
                    // the decimal text of the nonce, after the salt
                    var rest = nonce
                    var length = 0
                    repeat {
                        digits[length] = UInt8(48 + rest % 10)
                        rest /= 10
                        length += 1
                    } while rest > 0
                    for position in 0..<length { text[prefix.count + position] = digits[length - 1 - position] }
                    CC_SHA256(text.baseAddress, CC_LONG(prefix.count + length), hash.baseAddress)

                    var matches = true
                    for (position, nibble) in nibbles.enumerated() {
                        let byte = hash[position / 2]
                        if (position % 2 == 0 ? byte >> 4 : byte & 0x0f) != nibble {
                            matches = false
                            break
                        }
                    }
                    if matches { return nonce }
                    nonce += 1
                }
                return nil
            }
        }
    }
}
