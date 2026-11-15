import Foundation
import Testing
@testable import ObertonCore

// Windows forces day-first dates (DashboardPage, HistoryPage, AnalyticsPage, NotesStore), whatever the region.

@Suite struct DateTextTests {
    let us = Locale(identifier: "en_US")
    // Tuesday 3 November 2026, 14:05 in the test's own time zone.
    var date: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5))! }

    @Test func dayComesBeforeTheMonthEvenInTheUS() {
        #expect(DateText.weekdayDayMonth(date, locale: us) == "Tuesday 3 November")
        #expect(DateText.dayMonth(date, locale: us) == "3 Nov")
        #expect(DateText.dayMonthTime24(date, locale: us) == "3 Nov 14:05")
        #expect(DateText.weekdayDayMonthYearTime(date, locale: us) == "Tuesday 3 November 2026, 14:05")
        #expect(DateText.month(date, locale: us) == "Nov")
    }

    @Test func timeFollowsTheRegion() {
        #expect(DateText.time(date, locale: us).replacingOccurrences(of: "\u{202F}", with: " ") == "2:05 PM")
        #expect(DateText.time(date, locale: Locale(identifier: "en_GB")) == "14:05")
        #expect(DateText.dayMonthTime(date, locale: Locale(identifier: "en_GB")) == "3 Nov, 14:05")
    }

    @Test func namesFollowTheLanguage() {
        #expect(DateText.weekdayDayMonth(date, locale: Locale(identifier: "de_DE")) == "Dienstag 3 November")
    }
}
