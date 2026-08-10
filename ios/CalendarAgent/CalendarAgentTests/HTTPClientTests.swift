import Foundation
import XCTest
@testable import CalendarAgent

private final class HostedMockURLProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(
        self,
        didFailWithError: URLError(.unknown)
      )
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(
        self,
        didReceive: response,
        cacheStoragePolicy: .notAllowed
      )
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

final class HTTPClientTests: XCTestCase {
  override func tearDown() {
    HostedMockURLProtocol.handler = nil
    super.tearDown()
  }

  func testAgentTurnSendsOnlyDeploymentCredentialWithBoundedRequest() async throws {
    var capturedRequest: URLRequest?
    HostedMockURLProtocol.handler = { request in
      capturedRequest = request
      return (
        try self.response(
          for: request,
          statusCode: 200,
          requestID: "11111111-1111-1111-1111-111111111111"
        ),
        Data(
          """
          {
            "request_id": "11111111-1111-1111-1111-111111111111",
            "message": "Ready",
            "proposals": [],
            "check_in_question": null,
            "warnings": [],
            "provider": "openai",
            "model": "server-model",
            "focus_review": null
          }
          """.utf8
        )
      )
    }
    let client = makeClient()

    _ = try await client.sendTurn(
      makeTurnRequest(),
      appSecret: "deployment-secret"
    )

    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/api/v1/agent/turn")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "X-App-Secret"),
      "deployment-secret"
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "X-AI-API-Key"))
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertEqual(request.timeoutInterval, 60)
  }

  func testAuthenticatedStatusSendsNoUserContentAndDecodesServerConfiguration()
    async throws {
    var capturedRequest: URLRequest?
    HostedMockURLProtocol.handler = { request in
      capturedRequest = request
      return (
        try self.response(
          for: request,
          statusCode: 200,
          requestID: "22222222-2222-2222-2222-222222222222"
        ),
        Data(
          """
          {
            "status": "ok",
            "service": "calendar-agent",
            "provider": "openai",
            "model": "gpt-server",
            "byok_enabled": false,
            "audit_persistence_enabled": false
          }
          """.utf8
        )
      )
    }

    let status = try await makeClient().checkStatus(
      appSecret: "deployment-secret"
    )

    XCTAssertEqual(status.provider, "openai")
    XCTAssertEqual(status.model, "gpt-server")
    XCTAssertFalse(status.byokEnabled)
    XCTAssertFalse(status.auditPersistenceEnabled)
    let request = try XCTUnwrap(capturedRequest)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.path, "/api/v1/status")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "X-App-Secret"),
      "deployment-secret"
    )
    XCTAssertNil(request.httpBody)
    XCTAssertNil(request.value(forHTTPHeaderField: "X-AI-API-Key"))
  }

  func testStatusRejectsBYOKEnabledBackend() async throws {
    HostedMockURLProtocol.handler = { request in
      (
        try self.response(
          for: request,
          statusCode: 200,
          requestID: "33333333-3333-3333-3333-333333333333"
        ),
        Data(
          """
          {
            "status": "ok",
            "service": "calendar-agent",
            "provider": "openai",
            "model": "gpt-server",
            "byok_enabled": true,
            "audit_persistence_enabled": false
          }
          """.utf8
        )
      )
    }

    do {
      _ = try await makeClient().checkStatus(appSecret: "deployment-secret")
      XCTFail("Expected an incompatible hosted backend error")
    } catch let HTTPClientError.incompatibleBackend(requestID) {
      XCTAssertEqual(
        requestID,
        "33333333-3333-3333-3333-333333333333"
      )
    }
  }

  func testAuthenticationFailureIsDistinctAndIncludesRequestID() async throws {
    HostedMockURLProtocol.handler = { request in
      (
        try self.response(
          for: request,
          statusCode: 401,
          requestID: "44444444-4444-4444-4444-444444444444"
        ),
        Data(#"{"detail":"internal deployment detail"}"#.utf8)
      )
    }

    do {
      _ = try await makeClient().checkStatus(appSecret: "wrong-secret")
      XCTFail("Expected authentication to fail")
    } catch let error as HTTPClientError {
      guard case .authentication(let requestID) = error else {
        return XCTFail("Expected authentication error, got \(error)")
      }
      XCTAssertEqual(
        requestID,
        "44444444-4444-4444-4444-444444444444"
      )
      XCTAssertTrue(error.localizedDescription.contains("app secret"))
      XCTAssertTrue(error.localizedDescription.contains("Request ID"))
      XCTAssertFalse(error.localizedDescription.contains("internal deployment"))
    }
  }

  func testServerFailureDoesNotExposeBackendDetail() async throws {
    HostedMockURLProtocol.handler = { request in
      (
        try self.response(
          for: request,
          statusCode: 503,
          requestID: "55555555-5555-5555-5555-555555555555"
        ),
        Data(#"{"detail":"secret provider traceback"}"#.utf8)
      )
    }

    do {
      _ = try await makeClient().checkStatus(appSecret: "deployment-secret")
      XCTFail("Expected the server request to fail")
    } catch let error as HTTPClientError {
      guard case .server(let status, let requestID) = error else {
        return XCTFail("Expected server error, got \(error)")
      }
      XCTAssertEqual(status, 503)
      XCTAssertEqual(
        requestID,
        "55555555-5555-5555-5555-555555555555"
      )
      XCTAssertFalse(error.localizedDescription.contains("secret provider"))
      XCTAssertTrue(error.localizedDescription.contains("Request ID"))
    }
  }

  func testTransportFailureUsesSanitizedOfflineMessage() async throws {
    HostedMockURLProtocol.handler = { _ in
      throw URLError(
        .notConnectedToInternet,
        userInfo: [NSURLErrorFailingURLStringErrorKey: "https://private.example/secret"]
      )
    }

    do {
      _ = try await makeClient().checkStatus(appSecret: "deployment-secret")
      XCTFail("Expected the transport request to fail")
    } catch let error as HTTPClientError {
      XCTAssertEqual(
        error.localizedDescription,
        "No network connection. Reconnect and try again."
      )
      XCTAssertFalse(error.localizedDescription.contains("private.example"))
    }
  }

  private func makeClient() -> URLSessionHTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HostedMockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return URLSessionHTTPClient(
      baseURL: URL(string: "https://planner.example/api/v1")!,
      session: session
    )
  }

  private func response(
    for request: URLRequest,
    statusCode: Int,
    requestID: String
  ) throws -> HTTPURLResponse {
    try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(request.url),
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["X-Request-ID": requestID]
      )
    )
  }

  private func makeTurnRequest() -> AgentTurnRequest {
    let now = Date(timeIntervalSince1970: 1_784_208_000)
    return AgentTurnRequest(
      deviceId: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      message: "Private message that must stay out of logs",
      calendarActionRequested: false,
      focusReviewRequested: false,
      focusReviewPeriod: nil,
      focusReviewStart: nil,
      focusReviewEnd: nil,
      calendarContextTruncated: false,
      reviewCalendarContextTruncated: false,
      provider: .openai,
      model: nil,
      currentTime: now,
      planningStart: now,
      planningEnd: now.addingTimeInterval(86_400),
      trackingStartedAt: now,
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
      reviewCalendar: [],
      notes: [],
      history: []
    )
  }
}
