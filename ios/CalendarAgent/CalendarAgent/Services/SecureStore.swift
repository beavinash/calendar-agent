import Foundation
import Security

protocol SecureStore {
  func save(_ value: String, for key: String) throws
  func read(_ key: String) throws -> String?
  func delete(_ key: String) throws
}

enum SecureStoreError: LocalizedError {
  case encoding
  case unexpectedData
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .encoding:
      "The value could not be encoded."
    case .unexpectedData:
      "Keychain returned unexpected data."
    case .status(let status):
      "Keychain operation failed (\(status))."
    }
  }
}

final class KeychainSecureStore: SecureStore {
  private let service: String

  init(service: String = "ai.calendaragent.ios") {
    self.service = service
  }

  func save(_ value: String, for key: String) throws {
    guard let data = value.data(using: .utf8) else {
      throw SecureStoreError.encoding
    }
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key
    ]
    let updates: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String:
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ]
    let updateStatus = SecItemUpdate(
      lookup as CFDictionary,
      updates as CFDictionary
    )
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw SecureStoreError.status(updateStatus)
    }

    var add = lookup
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] =
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw SecureStoreError.status(addStatus)
    }
  }

  func read(_ key: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw SecureStoreError.status(status)
    }
    guard let data = result as? Data,
          let value = String(data: data, encoding: .utf8) else {
      throw SecureStoreError.unexpectedData
    }
    return value
  }

  func delete(_ key: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecureStoreError.status(status)
    }
  }
}
