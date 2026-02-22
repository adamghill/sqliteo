import Testing

@testable import SQLiteo

@Suite("Fuzzy Match Tests")
struct FuzzyMatchTests {

    @Test(
        "Positive matches",
        arguments: [
            ("account_emailaddress", "account_emailaddress"),
            ("account_emailaddress", "account"),
            ("account_emailaddress", "acc"),
            ("account_emailaddress", "email"),
            ("account_emailaddress", "acount_emailaddr"),
            ("auth_blob", "auto_"),
            ("account_emailaddress", "acount"),
            ("account_emailaddress", "ACCOUNT"),
            ("ACCOUNT_EMAILADDRESS", "acount"),
        ])
    func positiveMatches(target: String, query: String) {
        #expect(target.fuzzyMatch(query: query))
    }

    @Test(
        "Negative matches",
        arguments: [
            ("user", "user_account_details"),
            ("auth_blob", "xyz_"),
        ])
    func negativeMatches(target: String, query: String) {
        #expect(!target.fuzzyMatch(query: query))
    }
}
