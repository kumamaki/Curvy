import Foundation

/// One resolved `@<token>` in a message body. `name` is the canonical
/// full display name that rides the wire in `TextMessage.mentions`
/// and that `announceIfNeeded` checks against the local user's
/// `Preferences.displayName`. `handle` is the textual form the user
/// actually typed (or would type) in the body — the first word of
/// `name` when no other sender shares it, the full name otherwise.
struct MentionMatch: Equatable, Hashable, Sendable {
    let name: String
    let handle: String
}

/// Stateless helpers for resolving `@<handle>` and `@<name>` tokens
/// against the live set of known senders. The "known senders" list
/// is derived from the SwiftData cache (`Set(messages.map(\.sender))`)
/// so the resolver stays a pure function with no observable state.
///
/// Two namespaces deliberately:
///   - **Wire / notification namespace**: full canonical display
///     names. `mentions: [String]?` on the wire, `displayName`
///     comparisons in `announceIfNeeded`. Stable across all clients.
///   - **Body / picker namespace**: handles. Shorter when unambiguous
///     ("Mehdi Khaledi" → `@Mehdi`), full name when two friends would
///     otherwise collide on the same first word.
///
/// Boundary rules — kept consistent with the renderer in
/// `MessageRow.highlightedBody`:
///   - `@` must be at start of body or preceded by whitespace, so
///     `foo@bar.com` doesn't match
///   - the token must be followed by end-of-body, whitespace, or
///     punctuation, so `@Mehdi.` matches but `@Mehdiz` does not
///   - longer tokens match first and matched ranges are masked, so
///     `@Mehdi Khaledi` (when explicitly typed) beats `@Mehdi`
enum MentionResolver {
    /// First-word-or-fall-back-to-full-name handle for each sender.
    /// "Mehdi Khaledi" → "Mehdi" when it's the only "Mehdi" in the
    /// room. If two senders would share a first word ("Alice Smith",
    /// "Alice Jones"), both fall back to their full names so `@Alice`
    /// can never ambiguously match either of them.
    static func handles(for senders: [String]) -> [String: String] {
        var firstWordCounts: [String: Int] = [:]
        for s in senders {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            firstWordCounts[firstWord(of: trimmed), default: 0] += 1
        }
        var map: [String: String] = [:]
        for s in senders {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let first = firstWord(of: trimmed)
            if first != trimmed && firstWordCounts[first, default: 0] == 1 {
                map[trimmed] = first
            } else {
                map[trimmed] = trimmed
            }
        }
        return map
    }

    /// Resolve every `@<token>` in `body` to its canonical sender,
    /// matching either the handle ("@Mehdi") or the full name
    /// ("@Mehdi Khaledi"). Deduplicated, sorted by canonical name.
    static func resolve(in body: String, against senders: [String]) -> [MentionMatch] {
        guard !body.isEmpty, !senders.isEmpty else { return [] }
        let handleMap = handles(for: senders)

        // Build a search list keyed on every recognizable token —
        // both the handle AND the full name when they differ. Sorted
        // longest-first so the explicit form wins over a prefix.
        var searchTokens: [(token: String, name: String)] = []
        for sender in senders {
            let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            searchTokens.append((token: trimmed, name: trimmed))
            if let handle = handleMap[trimmed], handle != trimmed {
                searchTokens.append((token: handle, name: trimmed))
            }
        }
        searchTokens.sort { $0.token.count > $1.token.count }

        var found: Set<String> = []
        var scratch = body
        for pair in searchTokens where !pair.token.isEmpty {
            let bodyToken = "@" + pair.token
            var searchStart = scratch.startIndex
            while searchStart < scratch.endIndex,
                  let range = scratch.range(of: bodyToken, range: searchStart..<scratch.endIndex)
            {
                let preOK = range.lowerBound == scratch.startIndex
                    || scratch[scratch.index(before: range.lowerBound)].isWhitespace
                let postOK = range.upperBound == scratch.endIndex
                    || scratch[range.upperBound].isWhitespace
                    || scratch[range.upperBound].isPunctuation
                if preOK && postOK {
                    found.insert(pair.name)
                    let placeholder = String(repeating: " ", count: bodyToken.count)
                    scratch.replaceSubrange(range, with: placeholder)
                    searchStart = scratch.startIndex
                } else {
                    searchStart = scratch.index(after: range.lowerBound)
                }
            }
        }
        return found
            .map { MentionMatch(name: $0, handle: handleMap[$0] ?? $0) }
            .sorted { $0.name < $1.name }
    }

    /// Locate every `@<token>` span in `body` for the given resolved
    /// mentions, using the same boundary rules as `resolve(in:against:)`.
    /// Returns the matched ranges sorted by position, with no overlaps.
    /// Used by the renderer to build pill segments without duplicating
    /// the scanning logic.
    static func pillRanges(
        in body: String,
        resolutions: [MentionMatch]
    ) -> [(range: Range<String.Index>, name: String, token: String)] {
        guard !body.isEmpty, !resolutions.isEmpty else { return [] }

        var candidates: [(token: String, name: String)] = []
        for match in resolutions {
            candidates.append((token: match.name, name: match.name))
            if match.handle != match.name {
                candidates.append((token: match.handle, name: match.name))
            }
        }
        candidates.sort { $0.token.count > $1.token.count }

        var result: [(range: Range<String.Index>, name: String, token: String)] = []
        var consumed: [Range<String.Index>] = []
        for cand in candidates where !cand.token.isEmpty {
            let bodyToken = "@" + cand.token
            var cursor = body.startIndex
            while cursor < body.endIndex,
                  let range = body.range(of: bodyToken, range: cursor..<body.endIndex)
            {
                if consumed.contains(where: { $0.overlaps(range) }) {
                    cursor = body.index(after: range.lowerBound)
                    continue
                }
                let preOK = range.lowerBound == body.startIndex
                    || body[body.index(before: range.lowerBound)].isWhitespace
                let postOK = range.upperBound == body.endIndex
                    || body[range.upperBound].isWhitespace
                    || body[range.upperBound].isPunctuation
                if preOK && postOK {
                    consumed.append(range)
                    result.append((range: range, name: cand.name, token: cand.token))
                    cursor = range.upperBound
                } else {
                    cursor = body.index(after: range.lowerBound)
                }
            }
        }
        result.sort { $0.range.lowerBound < $1.range.lowerBound }
        return result
    }

    private static func firstWord(of name: String) -> String {
        name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? name
    }
}
