import Foundation

struct ContactIdentity: Hashable, Sendable {
    let id: String
    let displayName: String
    let aliases: [String]
    let handles: [String]

    var normalizedTokens: Set<String> {
        Set((aliases + [displayName]).flatMap(IdentityResolver.tokens)
            + handles.flatMap { IdentityResolver.searchVariants(for: $0).flatMap(IdentityResolver.tokens) })
    }
}

struct IdentityResolver: Sendable {
    private let identities: [ContactIdentity]

    init(identities: [ContactIdentity] = []) {
        self.identities = Self.consolidate(identities)
    }

    func resolve(_ query: String) -> [ContactIdentity] {
        let tokens = Set(Self.tokens(query))
        guard !tokens.isEmpty else { return [] }
        return identities.filter { identity in
            let identityTokens = identity.normalizedTokens
            // A phrase containing several name/handle tokens must match the
            // complete phrase. Falling back to one overlapping token makes
            // “Sandra Martins” incorrectly match “Rafaela Martins”. A
            // single token intentionally remains ambiguous when it belongs
            // to more than one identity.
            return tokens.isSubset(of: identityTokens)
        }.sorted { lhs, rhs in
            let left = tokens.intersection(lhs.normalizedTokens).count
            let right = tokens.intersection(rhs.normalizedTokens).count
            if left != right { return left > right }
            let leftName = Self.normalize(lhs.displayName)
            let rightName = Self.normalize(rhs.displayName)
            if leftName != rightName { return leftName < rightName }
            return lhs.id < rhs.id
        }
    }

    /// Resolves an exact identity first, then permits only a one-edit typo in
    /// a single display-name/alias token. Handles are deliberately excluded
    /// from fuzzy matching so arbitrary topic words cannot become contacts.
    /// Returning every best-distance identity preserves the existing
    /// ambiguity guard instead of silently choosing among close matches.
    func resolveWithConservativeFuzzy(_ query: String) -> [ContactIdentity] {
        let exact = resolve(query)
        guard exact.isEmpty else { return exact }

        let queryTokens = Self.tokens(query)
        guard queryTokens.count == 1, let candidate = queryTokens.first, candidate.count >= 4 else { return [] }

        let scored: [(identity: ContactIdentity, distance: Int)] = identities.compactMap { identity in
            let nameTokens = (identity.aliases + [identity.displayName])
                .flatMap(Self.tokens)
                .filter { $0.count >= 4 && !$0.contains("@") && !Self.isPhoneLike($0) }
            guard let distance = nameTokens.map({ Self.editDistance(candidate, $0) }).min(), distance <= 1 else { return nil }
            return (identity, distance)
        }
        guard let bestDistance = scored.map(\.distance).min() else { return [] }
        return scored
            .filter { $0.distance == bestDistance }
            .map(\.identity)
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9@.+-]", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .joined(separator: " ")
    }

    static func tokens(_ value: String) -> [String] {
        normalize(value).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    static func searchVariants(for value: String) -> [String] {
        let normalized = normalize(value)
        var variants = [normalized]
        let digits = value.filter(\.isNumber)
        if isPhoneLike(value) { variants.append(digits) }
        return orderedUnique(variants)
    }

    static func matchesSearchTerm(_ term: String, against field: String) -> Bool {
        let normalizedTerm = normalize(term)
        let normalizedField = normalize(field)
        guard !normalizedTerm.isEmpty, !normalizedField.isEmpty else { return false }
        let termDigits = term.filter(\.isNumber)
        let fieldDigits = field.filter(\.isNumber)
        if isPhoneLike(term), isPhoneLike(field), termDigits.count >= 7, fieldDigits.count >= 7 {
            return termDigits == fieldDigits || termDigits.hasSuffix(fieldDigits) || fieldDigits.hasSuffix(termDigits)
        }
        return normalizedField.contains(normalizedTerm)
    }

    private static func isPhoneLike(_ value: String) -> Bool {
        guard !value.contains("@") else { return false }
        let digits = value.filter(\.isNumber)
        guard digits.count >= 7 else { return false }
        return value.allSatisfy { $0.isNumber || " +()-./".contains($0) }
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let rhsCharacters = Array(rhs)
        var previous = Array(0...rhsCharacters.count)
        for (row, lhsCharacter) in Array(lhs).enumerated() {
            var current = [row + 1]
            for (column, rhsCharacter) in rhsCharacters.enumerated() {
                let substitution = previous[column] + (lhsCharacter == rhsCharacter ? 0 : 1)
                let insertion = current[column] + 1
                let deletion = previous[column + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous.last ?? 0
    }

    private static func consolidate(_ identities: [ContactIdentity]) -> [ContactIdentity] {
        let groups = Dictionary(grouping: identities) { normalize($0.displayName) }
        return groups.map { normalizedName, cards in
            let orderedCards = cards.sorted {
                let leftID = normalize($0.id)
                let rightID = normalize($1.id)
                if leftID != rightID { return leftID < rightID }
                let leftName = normalize($0.displayName)
                let rightName = normalize($1.displayName)
                if leftName != rightName { return leftName < rightName }
                return $0.id < $1.id
            }
            let canonical = orderedCards[0]
            let aliases = orderedUnique(orderedCards.flatMap { card in
                card.aliases + (normalize(card.displayName) == normalizedName ? [] : [card.displayName])
            })
            let handles = orderedUnique(orderedCards.flatMap(\.handles))
            return ContactIdentity(
                id: orderedCards.map(\.id).min() ?? canonical.id,
                displayName: canonical.displayName,
                aliases: aliases,
                handles: handles
            )
        }.sorted {
            let leftName = normalize($0.displayName)
            let rightName = normalize($1.displayName)
            if leftName != rightName { return leftName < rightName }
            return $0.id < $1.id
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .sorted {
                let leftNormalized = normalize($0)
                let rightNormalized = normalize($1)
                if leftNormalized != rightNormalized { return leftNormalized < rightNormalized }
                return $0 < $1
            }
            .filter { seen.insert(normalize($0)).inserted }
    }
}
