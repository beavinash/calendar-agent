import Foundation

enum APIJSONCoding {
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds
      ]
      if let date = formatter.date(from: value) {
        return date
      }
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: value) {
        return date
      }
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO 8601 timestamp."
      )
    }
    return decoder
  }
}

struct BackendStatus: Decodable, Equatable {
  let status: String
  let service: String
  let provider: String
  let model: String
  let byokEnabled: Bool
  let auditPersistenceEnabled: Bool

  fileprivate var isCompatibleWithHostedMode: Bool {
    status == "ok"
      && service == "calendar-agent"
      && provider.lowercased() == "openai"
      && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !byokEnabled
  }
}

protocol HTTPClient {
  func sendTurn(
    _ turn: AgentTurnRequest,
    appSecret: String?
  ) async throws -> AgentTurnResponse

  func checkStatus(appSecret: String?) async throws -> BackendStatus
}

enum HTTPTransportFailure {
  case offline
  case timedOut
  case secureConnection
  case unreachable
}

enum HTTPClientError: LocalizedError {
  case invalidResponse(requestID: String?)
  case transport(HTTPTransportFailure)
  case authentication(requestID: String?)
  case server(status: Int, requestID: String?)
  case decoding(requestID: String?)
  case incompatibleBackend(requestID: String?)

  var errorDescription: String? {
    switch self {
    case .invalidResponse(let requestID):
      return withRequestID(
        "The backend returned an invalid response.",
        requestID
      )
    case .transport(.offline):
      return "No network connection. Reconnect and try again."
    case .transport(.timedOut):
      return "The backend timed out. Try again in a moment."
    case .transport(.secureConnection):
      return "A secure HTTPS connection to the backend could not be established."
    case .transport(.unreachable):
      return "The backend could not be reached. Check its URL and deployment status."
    case .authentication(let requestID):
      return withRequestID(
        "Backend authentication failed. Check the app secret in Settings.",
        requestID
      )
    case .server(let status, let requestID):
      let message: String
      switch status {
      case 403:
        message = "The backend rejected this app configuration."
      case 429:
        message = "The backend is rate limited. Try again later."
      case 500...599:
        message = "The backend is temporarily unavailable."
      default:
        message = "The backend rejected the request."
      }
      return withRequestID(message, requestID)
    case .decoding(let requestID):
      return withRequestID(
        "The backend response did not match the app contract.",
        requestID
      )
    case .incompatibleBackend(let requestID):
      return withRequestID(
        "The backend is not configured for server-managed OpenAI.",
        requestID
      )
    }
  }

  private func withRequestID(_ message: String, _ requestID: String?) -> String {
    guard let requestID else { return message }
    return "\(message) Request ID: \(requestID)."
  }
}

actor URLSessionHTTPClient: HTTPClient {
  private let baseURL: URL
  private let session: URLSession
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(baseURL: URL, session: URLSession? = nil) {
    self.baseURL = baseURL
    self.session = session ?? Self.makeSession()
    encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    decoder = APIJSONCoding.makeDecoder()
  }

  func sendTurn(
    _ turn: AgentTurnRequest,
    appSecret: String?
  ) async throws -> AgentTurnResponse {
    AppLogger.network.info("Starting agent turn request; endpoint=/agent/turn")
    var request = makeRequest(
      url: baseURL
        .appendingPathComponent("agent")
        .appendingPathComponent("turn"),
      method: "POST",
      appSecret: appSecret
    )
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try encoder.encode(turn)
    } catch {
      let nsError = error as NSError
      AppLogger.network.error(
        "Agent turn request encoding failed; domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw error
    }
    let result = try await perform(
      request,
      operation: "agent_turn",
      responseType: AgentTurnResponse.self
    )
    return result.value
  }

  func checkStatus(appSecret: String?) async throws -> BackendStatus {
    AppLogger.network.info("Starting authenticated status request; endpoint=/status")
    let request = makeRequest(
      url: baseURL.appendingPathComponent("status"),
      method: "GET",
      appSecret: appSecret
    )
    let result = try await perform(
      request,
      operation: "status",
      responseType: BackendStatus.self
    )
    guard result.value.isCompatibleWithHostedMode else {
      AppLogger.network.error(
        "Authenticated status reported incompatible hosted configuration; request_id=\(result.requestID ?? "missing", privacy: .public)"
      )
      throw HTTPClientError.incompatibleBackend(
        requestID: result.requestID
      )
    }
    AppLogger.network.info(
      "Authenticated status verified; provider=openai byok_enabled=false request_id=\(result.requestID ?? "missing", privacy: .public)"
    )
    return result.value
  }

  private func makeRequest(
    url: URL,
    method: String,
    appSecret: String?
  ) -> URLRequest {
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 60
    )
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
    if let appSecret, !appSecret.isEmpty {
      request.setValue(appSecret, forHTTPHeaderField: "X-App-Secret")
    }
    return request
  }

  private func perform<Response: Decodable>(
    _ request: URLRequest,
    operation: String,
    responseType: Response.Type
  ) async throws -> (value: Response, requestID: String?) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      let nsError = error as NSError
      AppLogger.network.error(
        "Backend transport failed; operation=\(operation, privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw HTTPClientError.transport(transportFailure(for: error))
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      AppLogger.network.error(
        "Backend returned a non-HTTP response; operation=\(operation, privacy: .public)"
      )
      throw HTTPClientError.invalidResponse(requestID: nil)
    }
    let requestID = sanitizedRequestID(from: httpResponse)
    AppLogger.network.info(
      "Backend response received; operation=\(operation, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) request_id=\(requestID ?? "missing", privacy: .public)"
    )
    guard (200...299).contains(httpResponse.statusCode) else {
      AppLogger.network.error(
        "Backend request failed; operation=\(operation, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) request_id=\(requestID ?? "missing", privacy: .public)"
      )
      if httpResponse.statusCode == 401 {
        throw HTTPClientError.authentication(requestID: requestID)
      }
      throw HTTPClientError.server(
        status: httpResponse.statusCode,
        requestID: requestID
      )
    }

    do {
      return (
        try decoder.decode(responseType, from: data),
        requestID
      )
    } catch {
      let nsError = error as NSError
      AppLogger.network.error(
        "Backend response decoding failed; operation=\(operation, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) request_id=\(requestID ?? "missing", privacy: .public) domain=\(nsError.domain, privacy: .private) code=\(nsError.code, privacy: .public)"
      )
      throw HTTPClientError.decoding(requestID: requestID)
    }
  }

  private func transportFailure(for error: Error) -> HTTPTransportFailure {
    guard let urlError = error as? URLError else {
      return .unreachable
    }
    switch urlError.code {
    case .notConnectedToInternet:
      return .offline
    case .timedOut:
      return .timedOut
    case .secureConnectionFailed,
         .serverCertificateHasBadDate,
         .serverCertificateUntrusted,
         .serverCertificateHasUnknownRoot,
         .serverCertificateNotYetValid,
         .clientCertificateRejected,
         .clientCertificateRequired:
      return .secureConnection
    default:
      return .unreachable
    }
  }

  private func sanitizedRequestID(
    from response: HTTPURLResponse
  ) -> String? {
    guard let rawValue = response.value(
      forHTTPHeaderField: "X-Request-ID"
    )?.trimmingCharacters(in: .whitespacesAndNewlines),
      let requestID = UUID(uuidString: rawValue) else {
      return nil
    }
    return requestID.uuidString.lowercased()
  }

  private static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 75
    configuration.waitsForConnectivity = false
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }
}
