import XCTest
@testable import CalendarAgent

final class CalendarIntentDetectorTests: XCTestCase {
  func testRecognizesExplicitNaturalLanguageSchedulingCommands() {
    let messages = [
      "Plan tomorrow",
      "Plan tomorrow using what I missed",
      "Plan five blocks",
      "Plan seven focus blocks",
      "Can you schedule work after 5:30?",
      "Please block 6:30 AM for study",
      "Protect a project block tomorrow morning",
      "Add an exercise event to my calendar",
      "/schedule an errand block"
    ]

    for message in messages {
      XCTAssertTrue(
        CalendarIntentDetector.requestsCalendarAction(message),
        message
      )
    }
  }

  func testRejectsOrdinaryCoachingAndDiscussionMessages() {
    let messages = [
      "Help me reset",
      "Why did you schedule that?",
      "Summarize my note about planning",
      "I feel unmotivated today",
      "Book recommendations for study",
      "Book recommendations at beginner level",
      "Create an event handler in Swift",
      "Create a calendar view in SwiftUI",
      "Create a 5 minute timer in Swift",
      "Plan an event handler in Swift",
      "Schedule a background job in Swift",
      "Schedule a training job tomorrow morning",
      "Create a focus area calendar",
      "Organize these notes",
      "Protect my privacy",
      "Protect my privacy today",
      "Block spam tomorrow"
    ]

    for message in messages {
      XCTAssertFalse(
        CalendarIntentDetector.requestsCalendarAction(message),
        message
      )
    }
  }

  func testMissedPatternPhraseDetectionRequiresPersonalPatternLanguage() {
    XCTAssertTrue(
      MissedPatternContextIntentDetector.requestsContext(
        "tomorrow using what I missed"
      )
    )
    XCTAssertFalse(
      MissedPatternContextIntentDetector.requestsContext(
        "tomorrow avoiding lunch"
      )
    )
  }
}
