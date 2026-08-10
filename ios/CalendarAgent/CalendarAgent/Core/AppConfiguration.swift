import Foundation

enum AppBrand {
  static let name = "Mark-1"
}

enum AppConfiguration {
  private static let localDevelopmentURL =
    "http://127.0.0.1:8000/api/v1"
  private static let placeholderHosts = ["api.example.com"]

  static var allowsInsecureLoopback: Bool {
#if targetEnvironment(simulator)
    true
#else
    false
#endif
  }

  static var defaultAPIBaseURLString: String {
    let configured = Bundle.main.object(
      forInfoDictionaryKey: "API_BASE_URL"
    ) as? String ?? ""
    return configuredAPIBaseURLString(
      from: configured,
      allowInsecureLoopback: allowsInsecureLoopback
    )
  }

  static func configuredAPIBaseURLString(
    from value: String,
    allowInsecureLoopback: Bool
  ) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty, allowInsecureLoopback {
      return localDevelopmentURL
    }
    return normalizedAPIBaseURL(
      from: trimmed,
      allowInsecureLoopback: allowInsecureLoopback
    )?.absoluteString ?? ""
  }

  static func normalizedAPIBaseURL(
    from value: String,
    allowInsecureLoopback: Bool
  ) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          var components = URLComponents(string: trimmed),
          components.user == nil,
          components.password == nil,
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased(),
          !host.isEmpty,
          !placeholderHosts.contains(host) else {
      return nil
    }

    let isHTTPS = scheme == "https"
    let permitsLocalHTTP = scheme == "http"
      && allowInsecureLoopback
      && isLoopbackHost(host)
    guard isHTTPS || permitsLocalHTTP else {
      return nil
    }

    components.scheme = scheme
    components.path = "/api/v1"
    components.query = nil
    components.fragment = nil
    return components.url
  }

  static func requiresDeploymentCredential(for baseURL: URL) -> Bool {
    guard allowsInsecureLoopback,
          baseURL.scheme?.lowercased() == "http",
          let host = baseURL.host?.lowercased(),
          isLoopbackHost(host) else {
      return true
    }
    return false
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    host == "localhost" || host == "::1" || host.hasPrefix("127.")
  }
}
