import XCTest
@testable import CalendarAgent

final class APIContractTests: XCTestCase {
  func testTurnEncodesBackendSnakeCaseContract() throws {
    let now = Date(timeIntervalSince1970: 1_784_208_000)
    let trackingStartedAt = now.addingTimeInterval(-22 * 86_400)
    let reviewStart = Date(timeIntervalSince1970: 1_780_272_000)
    let reviewEnd = Date(timeIntervalSince1970: 1_782_864_000)
    let planningStart = Date(timeIntervalSince1970: 1_784_246_400)
    let planningEnd = Date(timeIntervalSince1970: 1_784_851_200)
    let reviewEvent = CalendarEventSnapshot(
      eventId: "review-event",
      calendarId: "calendar-1",
      startAt: now.addingTimeInterval(-20 * 86_400),
      endAt: now.addingTimeInterval((-20 * 86_400) + 3_600),
      isAllDay: false,
      title: "Project planning",
      focusArea: .work,
      completionStatus: .complete
    )
    let request = AgentTurnRequest(
      deviceId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      message: "Review my Apple Calendar by interest area",
      calendarActionRequested: false,
      focusReviewRequested: true,
      focusReviewPeriod: .month,
      focusReviewStart: reviewStart,
      focusReviewEnd: reviewEnd,
      calendarContextTruncated: false,
      reviewCalendarContextTruncated: true,
      missedPatternContext: MissedPatternContextPayload(
        sourceReviewPeriod: .month,
        windowStartAt: reviewStart,
        windowEndAt: reviewEnd,
        trackingCoverage: .partial,
        evaluatedEventCount: 7,
        coveredEvaluatedEventCount: 5,
        missedEventCount: 6,
        inferredUnmarkedCount: 4,
        explicitIncompleteCount: 2,
        omittedGroupCount: 0,
        groups: [
          MissedPatternGroupPayload(
            rank: 1,
            displayTitle: "Study session",
            missedCount: 6,
            inferredUnmarkedCount: 4,
            explicitIncompleteCount: 2
          )
        ]
      ),
      provider: .openai,
      model: "gpt-test",
      currentTime: now,
      planningStart: planningStart,
      planningEnd: planningEnd,
      trackingStartedAt: trackingStartedAt,
      preferences: CalendarPreferencesPayload(
        timezone: "UTC",
        weekStartsOn: 2,
        dayStart: "06:00:00",
        morningEnd: "08:00:00",
        eveningStart: "17:30:00",
        dayEnd: "23:00:00",
        weekendStart: "06:00:00",
        weekendEnd: "23:00:00",
        breakfastStart: "07:45:00",
        breakfastEnd: "08:15:00",
        lunchStart: "11:30:00",
        lunchEnd: "12:00:00",
        dinnerStart: "19:00:00",
        dinnerEnd: "19:30:00",
        minimumBreakMinutes: 10,
        maxDailyBlocks: 5,
        selectedFocusAreas: [.work]
      ),
      calendar: [],
      reviewCalendar: [reviewEvent],
      notes: [],
      history: []
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(request)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let preferences = try XCTUnwrap(
      json["preferences"] as? [String: Any]
    )

    XCTAssertNotNil(json["device_id"])
    XCTAssertEqual(json["calendar_action_requested"] as? Bool, false)
    XCTAssertEqual(json["focus_review_requested"] as? Bool, true)
    XCTAssertEqual(json["focus_review_period"] as? String, "month")
    XCTAssertNotNil(json["focus_review_start"])
    XCTAssertNotNil(json["focus_review_end"])
    XCTAssertEqual(json["calendar_context_truncated"] as? Bool, false)
    XCTAssertEqual(
      json["review_calendar_context_truncated"] as? Bool,
      true
    )
    let missedContext = try XCTUnwrap(
      json["missed_pattern_context"] as? [String: Any]
    )
    XCTAssertEqual(
      missedContext["source_review_period"] as? String,
      "month"
    )
    XCTAssertEqual(json["review_suggestion_count"] as? Int, 7)
    XCTAssertEqual(missedContext["missed_event_count"] as? Int, 6)
    let missedGroups = try XCTUnwrap(
      missedContext["groups"] as? [[String: Any]]
    )
    XCTAssertEqual(missedGroups.first?["display_title"] as? String, "Study session")
    XCTAssertNil(missedGroups.first?["event_id"])
    XCTAssertNil(missedGroups.first?["calendar_id"])
    XCTAssertNotNil(json["planning_start"])
    XCTAssertNotNil(json["tracking_started_at"])
    let reviewCalendar = try XCTUnwrap(
      json["review_calendar"] as? [[String: Any]]
    )
    XCTAssertEqual(reviewCalendar.count, 1)
    XCTAssertEqual(reviewCalendar[0]["title"] as? String, "Project planning")
    XCTAssertEqual(reviewCalendar[0]["completion_status"] as? String, "complete")
    XCTAssertEqual(preferences["week_starts_on"] as? Int, 2)
    XCTAssertEqual(preferences["minimum_break_minutes"] as? Int, 10)
    XCTAssertEqual(preferences["morning_end"] as? String, "08:00:00")
    XCTAssertEqual(
      preferences["evening_start"] as? String,
      "17:30:00"
    )
    XCTAssertEqual(preferences["max_daily_blocks"] as? Int, 5)
    XCTAssertEqual(preferences["weekend_start"] as? String, "06:00:00")
    XCTAssertEqual(preferences["weekend_end"] as? String, "23:00:00")
    XCTAssertEqual(preferences["breakfast_start"] as? String, "07:45:00")
    XCTAssertEqual(preferences["breakfast_end"] as? String, "08:15:00")
    XCTAssertEqual(preferences["lunch_start"] as? String, "11:30:00")
    XCTAssertEqual(preferences["lunch_end"] as? String, "12:00:00")
    XCTAssertEqual(preferences["dinner_start"] as? String, "19:00:00")
    XCTAssertEqual(preferences["dinner_end"] as? String, "19:30:00")
    XCTAssertEqual(
      preferences["selected_focus_areas"] as? [String],
      ["work"]
    )
  }

  func testTurnDecodesFractionalBackendTimestamps() throws {
    let json = """
      {
        "request_id": "11111111-1111-1111-1111-111111111111",
        "message": "Plan",
        "proposals": [
          {
            "proposal_id": "22222222-2222-2222-2222-222222222222",
            "title": "Project planning",
            "start_at": "2026-07-16T18:00:00.123456+00:00",
            "end_at": "2026-07-16T19:00:00+00:00",
            "focus_area": "work",
            "rationale": "Protected focus time",
            "notes": "",
            "reminder_minutes": 10
          }
        ],
        "check_in_question": null,
        "warnings": [],
        "provider": "openai",
        "model": "gpt-test",
        "focus_review": {
          "areas": [
            {
              "focus_area": "work",
              "recent_visibility": "not_visible",
              "upcoming_visibility": "visible",
              "scheduled_evidence": "One upcoming block is visible.",
              "likely_impact": "May support the stated goal.",
              "confidence": "medium"
            }
          ],
          "next_adjustment": "Protect one small next block.",
          "suggested_events": [
            {
              "focus_area": "work",
              "title": "Project planning",
              "suggested_start_at": "2026-07-17T18:00:00+00:00",
              "suggested_end_at": "2026-07-17T18:45:00+00:00",
              "rationale": "May restore visible time for this goal.",
              "confidence": "medium",
              "action": "requires_explicit_scheduling"
            },
            {
              "focus_area": "study",
              "title": "Study session",
              "suggested_start_at": "2026-07-18T18:00:00+00:00",
              "suggested_end_at": "2026-07-18T19:00:00+00:00",
              "rationale": "Build consistency in study time.",
              "confidence": "medium",
              "action": "requires_explicit_scheduling"
            },
            {
              "focus_area": "exercise",
              "title": "Exercise session",
              "suggested_start_at": "2026-07-19T18:00:00+00:00",
              "suggested_end_at": "2026-07-19T19:00:00+00:00",
              "rationale": "Protect time for movement.",
              "confidence": "medium",
              "action": "requires_explicit_scheduling"
            },
            {
              "focus_area": "appointments",
              "title": "Scheduled appointment",
              "suggested_start_at": "2026-07-20T18:00:00+00:00",
              "suggested_end_at": "2026-07-20T19:00:00+00:00",
              "rationale": "Protect the scheduled appointment.",
              "confidence": "medium",
              "action": "requires_explicit_scheduling"
            },
            {
              "focus_area": "errands",
              "title": "Grocery pickup",
              "suggested_start_at": "2026-07-21T18:00:00+00:00",
              "suggested_end_at": "2026-07-21T19:00:00+00:00",
              "rationale": "Set aside time for an errand.",
              "confidence": "medium",
              "action": "requires_explicit_scheduling"
            },
            {
              "focus_area": "work",
              "title": "Team follow-up",
              "suggested_start_at": "2026-07-22T18:00:00+00:00",
              "suggested_end_at": "2026-07-22T19:00:00+00:00",
              "rationale": "Protect time for a work follow-up.",
              "confidence": "medium",
              "action": "requires_explicit_scheduling"
            },
            {
              "focus_area": "study",
              "title": "Reading session",
              "suggested_start_at": "2026-07-23T06:00:00+00:00",
              "suggested_end_at": "2026-07-23T07:00:00+00:00",
              "rationale": "Finish one concrete study task.",
              "confidence": "medium",
              "action": "requires_explicit_scheduling"
            }
          ],
          "period": "month",
          "recent_start_at": "2026-06-18T08:00:00+00:00",
          "period_end_at": "2026-07-01T08:00:00+00:00",
          "current_time": "2026-07-16T08:00:00+00:00",
          "upcoming_end_at": "2026-07-23T08:00:00+00:00",
          "tracking_started_at": "2026-06-25T08:00:00+00:00",
          "history_coverage": "partial",
          "completion_evidence": "user_input",
          "context_truncated": false
        }
      }
      """

    let response = try APIJSONCoding.makeDecoder().decode(
      AgentTurnResponse.self,
      from: Data(json.utf8)
    )

    XCTAssertEqual(response.proposals.count, 1)
    XCTAssertGreaterThan(
      response.proposals[0].endAt,
      response.proposals[0].startAt
    )
    XCTAssertEqual(response.focusReview?.areas.count, 1)
    XCTAssertEqual(
      response.focusReview?.areas[0].recentVisibility,
      .notVisible
    )
    XCTAssertEqual(
      response.focusReview?.completionEvidence,
      .userInput
    )
    XCTAssertEqual(response.focusReview?.historyCoverage, .partial)
    XCTAssertNotNil(response.focusReview?.periodEndAt)
    XCTAssertNotNil(response.focusReview?.trackingStartedAt)
    XCTAssertEqual(response.focusReview?.period, .month)
    XCTAssertEqual(response.focusReview?.suggestedEvents.count, 7)
    XCTAssertEqual(
      response.focusReview?.suggestedEvents.first?.action,
      .requiresExplicitScheduling
    )
  }

  func testTurnDecodesReviewWithNoSuggestions() throws {
    let json = """
      {
        "areas": [],
        "next_adjustment": "Keep observing the calendar.",
        "suggested_events": [],
        "period": "month",
        "recent_start_at": "2026-06-01T00:00:00+00:00",
        "period_end_at": "2026-07-01T00:00:00+00:00",
        "current_time": "2026-07-16T08:00:00+00:00",
        "upcoming_end_at": "2026-07-24T08:00:00+00:00",
        "tracking_started_at": "2026-07-10T08:00:00+00:00",
        "history_coverage": "before_tracking",
        "completion_evidence": "not_provided",
        "context_truncated": false
      }
      """

    let review = try APIJSONCoding.makeDecoder().decode(
      FocusReviewResult.self,
      from: Data(json.utf8)
    )

    XCTAssertTrue(review.suggestedEvents.isEmpty)
    XCTAssertEqual(review.historyCoverage, .beforeTracking)
    XCTAssertEqual(review.completionEvidence, .notProvided)
  }
}
