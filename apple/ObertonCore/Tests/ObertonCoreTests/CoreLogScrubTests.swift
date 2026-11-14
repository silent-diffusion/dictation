import Testing
@testable import ObertonCore

/// The home folder never reaches the log (the file or the system log): it is written "~".
@Suite struct CoreLogScrubTests {
    @Test func homeFolderBecomesTilde() {
        let home = "/home/somebody"
        #expect(CoreLog.scrubbed("Could not read /home/somebody/Library/x.json", home: home) == "Could not read ~/Library/x.json")
        #expect(CoreLog.scrubbed("/HOME/Somebody/a and /home/somebody/b", home: home) == "~/a and ~/b")
        #expect(CoreLog.scrubbed("trailing slash /home/somebody/a", home: home + "/") == "trailing slash ~/a")
    }

    @Test func otherTextIsUntouched() {
        #expect(CoreLog.scrubbed("42 chars in 0.3 s", home: "/home/somebody") == "42 chars in 0.3 s")
        // A home too short to be one ("/", "") scrubs nothing.
        #expect(CoreLog.scrubbed("a/b/c", home: "/") == "a/b/c")
    }
}

/// A message that can echo what was said (a cloud service's error text) never reaches the log.
@Suite struct UserFacingErrorLogTests {
    @Test func logWordsReplaceTheMessageWhenGiven() {
        let echo = UserFacingError("Claude returned an error: invalid text 'my secret words'", log: "Claude returned an error (400)")
        #expect(echo.message.contains("my secret words"))
        #expect(echo.forLog == "Claude returned an error (400)")
        #expect(UserFacingError("The cloud model took too long to respond.").forLog == "The cloud model took too long to respond.")
    }
}
