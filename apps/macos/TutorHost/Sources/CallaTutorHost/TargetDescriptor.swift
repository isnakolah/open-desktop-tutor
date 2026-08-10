import Foundation

/// The authored App Pack `resolve:` contract for one semantic target.
///
/// TutorHost executes this instead of hardcoding any application, so adding an
/// app is authoring a pack rather than shipping a build.
struct TargetDescriptor {
    struct AccessibilityCandidate {
        let role: String?
        let labelPattern: BoundedPattern?
        let descriptionPattern: BoundedPattern?
    }

    struct Confidence {
        static let fallbackPoint = 0.72
        static let fallbackAct = 0.92

        let point: Double
        let act: Double
    }

    let semanticID: String
    let bundleIDs: [String]
    let accessibilityCandidates: [AccessibilityCandidate]
    let bridgeSelector: [String: String]
    let visualIcon: String?
    let expectedNeighbors: [String]
    let confidence: Confidence

    var hasAccessibilityContract: Bool { !accessibilityCandidates.isEmpty }
}

/// App Packs are untrusted input (SECURITY.md), and a pack-authored pattern is
/// therefore attacker-controlled input to a regex engine. Bound it on three
/// axes: pattern length, subject length, and catastrophic-backtracking shape.
struct BoundedPattern {
    static let maxPatternLength = 200
    static let maxSubjectLength = 256

    private let regex: NSRegularExpression

    init?(_ pattern: String) {
        guard !pattern.isEmpty, pattern.count <= Self.maxPatternLength else { return nil }
        guard !Self.hasNestedQuantifier(pattern) else { return nil }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        regex = compiled
    }

    func matches(_ subject: String) -> Bool {
        let bounded = String(subject.prefix(Self.maxSubjectLength))
        let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
        return regex.firstMatch(in: bounded, options: [], range: range) != nil
    }

    /// Rejects `(a+)+`-shaped patterns: a quantified group whose body is itself
    /// quantified, which is the classic exponential-backtracking construction.
    static func hasNestedQuantifier(_ pattern: String) -> Bool {
        var depth = 0
        var quantifierAtDepth: [Int: Bool] = [:]
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" { index += 2; continue }
            switch character {
            case "(":
                depth += 1
                quantifierAtDepth[depth] = false
            case ")":
                let innerHadQuantifier = quantifierAtDepth[depth] ?? false
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if innerHadQuantifier, next == "*" || next == "+" || next == "{" {
                    return true
                }
                quantifierAtDepth[depth] = false
                depth = max(0, depth - 1)
            case "*", "+", "{":
                if depth > 0 { quantifierAtDepth[depth] = true }
            default:
                break
            }
            index += 1
        }
        return false
    }
}

extension TargetDescriptor {
    /// Decodes the descriptor the gateway forwarded. Returns nil when absent so
    /// the caller can fail closed with `unsupported_target`.
    init?(payload: [String: JSONValue]) {
        guard case .object(let root)? = payload["target_descriptor"] else { return nil }
        guard case .string(let semanticID)? = root["semantic_id"], !semanticID.isEmpty else { return nil }
        self.semanticID = semanticID

        if case .array(let ids)? = root["bundle_ids"] {
            bundleIDs = ids.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
        } else {
            bundleIDs = []
        }

        var candidates: [AccessibilityCandidate] = []
        var selector: [String: String] = [:]
        var icon: String?
        if case .object(let resolve)? = root["resolve"] {
            if case .object(let accessibility)? = resolve["accessibility"],
               case .array(let rawCandidates)? = accessibility["candidates"] {
                for entry in rawCandidates {
                    guard case .object(let candidate) = entry else { continue }
                    var role: String?
                    if case .string(let value)? = candidate["role"] { role = value }
                    var labelPattern: BoundedPattern?
                    if case .string(let value)? = candidate["label_regex"] { labelPattern = BoundedPattern(value) }
                    var descriptionPattern: BoundedPattern?
                    if case .string(let value)? = candidate["description_regex"] { descriptionPattern = BoundedPattern(value) }
                    guard role != nil || labelPattern != nil || descriptionPattern != nil else { continue }
                    candidates.append(AccessibilityCandidate(role: role,
                                                             labelPattern: labelPattern,
                                                             descriptionPattern: descriptionPattern))
                }
            }
            if case .object(let bridge)? = resolve["bridge"], case .object(let raw)? = bridge["selector"] {
                for (key, value) in raw {
                    if case .string(let string) = value { selector[key] = string }
                }
            }
            if case .object(let visual)? = resolve["visual"], case .string(let value)? = visual["icon"] {
                icon = value
            }
        }
        accessibilityCandidates = candidates
        bridgeSelector = selector
        visualIcon = icon

        if case .object(let disambiguate)? = root["disambiguate"],
           case .array(let neighbors)? = disambiguate["expected_neighbors"] {
            expectedNeighbors = neighbors.compactMap { if case .string(let value) = $0 { return value } else { return nil } }
        } else {
            expectedNeighbors = []
        }

        var point = Confidence.fallbackPoint
        var act = Confidence.fallbackAct
        if case .object(let minimum)? = root["minimum_confidence"] {
            if case .number(let value)? = minimum["point"], (0...1).contains(value) { point = value }
            if case .number(let value)? = minimum["act"], (0...1).contains(value) { act = value }
        }
        confidence = Confidence(point: point, act: act)
    }
}
