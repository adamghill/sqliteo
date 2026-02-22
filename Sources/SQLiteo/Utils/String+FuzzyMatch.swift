import Foundation

extension String {
    /// Performs a substring-friendly Levenshtein distance check to determine if the query
    /// closely matches the string.
    func fuzzyMatch(query: String) -> Bool {
        if query.isEmpty { return true }

        let lowerString = self.lowercased()
        let lowerQuery = query.lowercased()

        // 1. Direct contains is the strongest match
        if lowerString.contains(lowerQuery) { return true }

        // 2. Simple Levenshtein distance implementation for short strings
        let m = lowerString.count
        let n = lowerQuery.count

        // If the query is much longer than the string, it's not a match
        if n > m + 3 { return false }

        var d = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        let sChars = Array(lowerString)
        let qChars = Array(lowerQuery)

        // Allow matching any substring: cost to skip prefix characters is 0
        for i in 0...m { d[i][0] = 0 }

        // Cost of matching empty string with query characters is just inserting them all
        for j in 0...n { d[0][j] = j }

        if m > 0 && n > 0 {
            for i in 1...m {
                for j in 1...n {
                    let cost = sChars[i - 1] == qChars[j - 1] ? 0 : 1
                    d[i][j] = Swift.min(
                        d[i - 1][j] + 1,  // deletion
                        d[i][j - 1] + 1,  // insertion
                        d[i - 1][j - 1] + cost  // substitution
                    )
                }
            }
        }

        // Allow 1 typo for every 3 characters, max 2 or 3
        let allowedTypos = max(1, min(3, lowerQuery.count / 3))

        // We want to know if the query is a prefix or contains the string with a few typos
        var minDistance = Int.max
        for i in 1...m {
            minDistance = Swift.min(minDistance, d[i][n])
        }

        return minDistance <= allowedTypos
    }
}
