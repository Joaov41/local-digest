import Foundation

struct ContactIdentity: Hashable, Sendable {
    let id: String
    let displayName: String
    let aliases: [String]
    let handles: [String]

    var normalizedTokens: Set<String> {
        Set((aliases + handles + [displayName]).flatMap(IdentityResolver.tokens))
    }
}

struct IdentityResolver: Sendable {
    private let identities: [ContactIdentity]

    init(identities: [ContactIdentity] = []) {
        self.identities = identities
    }

    func resolve(_ query: String) -> [ContactIdentity] {
        let tokens = Set(Self.tokens(query))
        guard !tokens.isEmpty else { return [] }
        return identities.filter { identity in
            let identityTokens = identity.normalizedTokens
            return tokens.isSubset(of: identityTokens) || tokens.contains(where: identityTokens.contains)
        }.sorted { lhs, rhs in
            let left = tokens.intersection(lhs.normalizedTokens).count
            let right = tokens.intersection(rhs.normalizedTokens).count
            return left > right
        }
    }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9@.+-]", with: " ", options: .regularExpression)
    }

    static func tokens(_ value: String) -> [String] {
        normalize(value).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }
}
