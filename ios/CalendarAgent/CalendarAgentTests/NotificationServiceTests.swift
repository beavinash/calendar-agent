import UserNotifications
import XCTest
@testable import CalendarAgent

private final class FakeNotificationScheduler: NotificationScheduling {
  var status: UNAuthorizationStatus = .authorized
  var grantsAuthorization = true
  private(set) var requests: [String: UNNotificationRequest] = [:]
  private(set) var removalCalls: [[String]] = []

  func currentAuthorizationStatus() async -> UNAuthorizationStatus {
    status
  }

  func requestAuthorization(
    options: UNAuthorizationOptions
  ) async throws -> Bool {
    grantsAuthorization
  }

  func add(_ request: UNNotificationRequest) async throws {
    requests[request.identifier] = request
  }

  func pendingNotificationIdentifiers() async -> Set<String> {
    Set(requests.keys)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    removalCalls.append(identifiers)
    for identifier in identifiers {
      requests.removeValue(forKey: identifier)
    }
  }
}

@MainActor
final class NotificationServiceTests: XCTestCase {
  private let seed = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }
  private var referenceDate: Date {
    calendar.date(
      from: DateComponents(
        year: 2026,
        month: 8,
        day: 7,
        hour: 12
      )
    )!
  }

  func testPlannerCreatesThreeDistinctPromptsPerDayWithVariedGaps() {
    let plans = ReflectionNotificationPlanner.plans(
      seed: seed,
      now: referenceDate,
      calendar: calendar
    )
    let grouped = Dictionary(grouping: plans, by: localDayKey)
    var allGaps: Set<Int> = []

    XCTAssertEqual(
      plans.count,
      ReflectionNotificationPlanner.horizonDays * 3
    )
    XCTAssertEqual(
      grouped.count,
      ReflectionNotificationPlanner.horizonDays
    )
    XCTAssertEqual(Set(plans.map(\.identifier)).count, plans.count)

    for dayPlans in grouped.values {
      let day = dayPlans.sorted {
        $0.minutesAfterMidnight < $1.minutesAfterMidnight
      }
      XCTAssertEqual(day.count, 3)
      XCTAssertEqual(day.first?.minutesAfterMidnight, 19 * 60 + 30)
      XCTAssertEqual(Set(day.map(\.message)).count, 3)
      for pair in zip(day, day.dropFirst()) {
        let gap = pair.1.minutesAfterMidnight - pair.0.minutesAfterMidnight
        XCTAssertTrue([40, 60].contains(gap))
        allGaps.insert(gap)
      }
    }

    XCTAssertEqual(allGaps, [40, 60])
    let notificationText = plans.map {
      "\($0.message.title) \($0.message.body)"
    }
    XCTAssertTrue(notificationText.contains { $0.contains("Mark-1") })
    let firstDaySignature = plans.prefix(3).map {
      "\($0.minutesAfterMidnight)|\($0.message.title)"
    }
    let followingWeekSignature = plans.dropFirst(7 * 3).prefix(3).map {
      "\($0.minutesAfterMidnight)|\($0.message.title)"
    }
    XCTAssertNotEqual(firstDaySignature, followingWeekSignature)
  }

  func testPlannerIsStableForInstallationButChangesAcrossInstallations() {
    let first = ReflectionNotificationPlanner.plans(
      seed: seed,
      now: referenceDate,
      calendar: calendar
    )
    let repeated = ReflectionNotificationPlanner.plans(
      seed: seed,
      now: referenceDate,
      calendar: calendar
    )
    let other = ReflectionNotificationPlanner.plans(
      seed: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      now: referenceDate,
      calendar: calendar
    )

    XCTAssertEqual(first, repeated)
    XCTAssertNotEqual(
      first.map(\.minutesAfterMidnight),
      other.map(\.minutesAfterMidnight)
    )
  }

  func testPlannerKeepsPastPromptsOutOfThePendingSchedule() {
    let lateEvening = calendar.date(
      from: DateComponents(
        year: 2026,
        month: 8,
        day: 7,
        hour: 22
      )
    )!
    let plans = ReflectionNotificationPlanner.plans(
      seed: seed,
      now: lateEvening,
      calendar: calendar
    )
    let firstDayKey = "2026-08-07"

    XCTAssertTrue(plans.allSatisfy { localDayKey($0) != firstDayKey })
    XCTAssertLessThanOrEqual(
      Dictionary(grouping: plans, by: localDayKey)
        .values.map(\.count).max() ?? 0,
      3
    )
  }

  func testConfigureSchedulesCompleteRollingSetAndRemovesLegacyRequest()
    async throws {
    let center = FakeNotificationScheduler()
    try await center.add(
      UNNotificationRequest(
        identifier: NotificationService.legacyIdentifier,
        content: UNNotificationContent(),
        trigger: nil
      )
    )
    let service = NotificationService(
      center: center,
      now: { self.referenceDate },
      calendar: calendar
    )

    try await service.configureDailyReview(enabled: true, seed: seed)
    let expectedPlans = Dictionary(
      uniqueKeysWithValues: ReflectionNotificationPlanner.plans(
        seed: seed,
        now: referenceDate,
        calendar: calendar
      ).map { ($0.identifier, $0) }
    )

    XCTAssertNil(center.requests[NotificationService.legacyIdentifier])
    XCTAssertEqual(
      center.requests.count,
      ReflectionNotificationPlanner.horizonDays * 3
    )
    XCTAssertTrue(
      center.requests.values.allSatisfy {
        guard let trigger = $0.trigger as? UNCalendarNotificationTrigger else {
          return false
        }
        guard let plan = expectedPlans[$0.identifier] else { return false }
        return !trigger.repeats && trigger.dateComponents.year != nil
          && trigger.dateComponents.year == plan.year
          && trigger.dateComponents.month == plan.month
          && trigger.dateComponents.day == plan.day
          && trigger.dateComponents.hour == plan.hour
          && trigger.dateComponents.minute == plan.minute
          && trigger.dateComponents.timeZone == nil
          && !$0.content.title.isEmpty
          && !$0.content.body.isEmpty
      }
    )
  }

  func testEnsureIsIdempotentAndDisableRemovesManagedSchedule() async throws {
    let center = FakeNotificationScheduler()
    let service = NotificationService(
      center: center,
      now: { self.referenceDate },
      calendar: calendar
    )
    try await service.configureDailyReview(enabled: true, seed: seed)
    let removalCount = center.removalCalls.count

    try await service.ensureDailyReview(enabled: true, seed: seed)

    XCTAssertEqual(center.removalCalls.count, removalCount)
    XCTAssertEqual(
      center.requests.count,
      ReflectionNotificationPlanner.horizonDays * 3
    )

    try await service.configureDailyReview(enabled: false, seed: seed)

    XCTAssertTrue(center.requests.isEmpty)
  }

  private func localDayKey(_ plan: ReflectionNotificationPlan) -> String {
    String(format: "%04d-%02d-%02d", plan.year, plan.month, plan.day)
  }
}
