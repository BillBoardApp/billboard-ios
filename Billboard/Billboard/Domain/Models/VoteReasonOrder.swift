import Foundation

/// The order the reasons picker shows a person's reasons in (feature review N13, project decision of 2026-10-28).
///
/// A fixed order would skew Why people voted by position: everyone saw the same three reasons before More reasons.
/// So each person gets the reasons shuffled once, from a seed that does not change: their account ID, or, before
/// one is known, an ID kept on this device. The same person sees the same order on every launch, on every bill,
/// after a Yea and after a Nay, and on every device they sign in on. The order never depends on how often others
/// pick a reason (INT-11), and nothing about it is sent anywhere.
nonisolated enum VoteReasonOrder {
    /// The `UserDefaults` key of this device's seed, used only while no account ID is known.
    static let deviceSeedKey = "BillBoard.voteReasonOrder.deviceSeed.v1"

    /// Mixed into the seed, so this order shares nothing with any other use of the account ID.
    private static let salt = "billboard.voteReasonOrder.v1|"

    /// `reasons` in the order for `seed`: a Fisher-Yates shuffle driven by SplitMix64 from the seed's FNV-1a
    /// hash. Both are written out here, since the standard library's `shuffled(using:)` and `Hasher` may change
    /// between iOS versions (and `Hasher` changes on every launch), and the order must not.
    static func order(of reasons: [VoteReason], seed: String) -> [VoteReason] {
        var result = reasons
        guard result.count > 1 else { return result }
        var generator = SplitMix64(state: fnv1a(salt + seed))
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            let other = Int(generator.next() % UInt64(index + 1))
            result.swapAt(index, other)
        }
        return result
    }

    /// The reasons offered after `voteType` (`VoteReason.offered(for:)`), in the person's order.
    static func order(for voteType: VoteType, seed: String) -> [VoteReason] {
        order(of: VoteReason.offered(for: voteType), seed: seed)
    }

    /// The seed: the account ID when there is one, else this device's seed, made once and kept.
    static func seed(accountID: String, defaults: UserDefaults = .standard) -> String {
        if let accountID = accountID.trimmedNonEmpty {
            return accountID
        }
        if let stored = defaults.string(forKey: deviceSeedKey)?.trimmedNonEmpty {
            return stored
        }
        let made = UUID().uuidString
        defaults.set(made, forKey: deviceSeedKey)
        return made
    }

    /// FNV-1a, 64 bit, over the string's UTF-8.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// SplitMix64 (Steele, Lea and Flood): small, fast and the same everywhere.
    struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
            return mixed ^ (mixed >> 31)
        }
    }
}
