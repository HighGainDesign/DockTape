// © 2026 High Gain Design. All rights reserved.
import Foundation
import LocalAuthentication
import Security

#if os(macOS)
  import IOKit
#endif

public enum SharedWriterIdentityError: Error, Sendable {
  case hardwareUnavailable, invalidNonce
  case keychain(OSStatus)
}

/// Local identity setup only. No hardware value/Keychain nonce enters shared
/// state. The host needs Data Protection Keychain entitlements; failure never
/// falls back to a synced/defaults identity or reuses another installation's ID.
public struct SharedWriterIdentityFactory: Sendable {
  private let directory: URL
  private let hardware: @Sendable () throws -> String
  private let nonce: @Sendable () throws -> Data
  public init(directory: URL? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    self.init(
      directory: directory ?? support.appendingPathComponent("DockTape/SharedLibraries/Identity"),
      hardware: { try Self.platformHardware() }, nonce: { try Self.deviceNonce() })
  }
  init(
    directory: URL, hardware: @escaping @Sendable () throws -> String,
    nonce: @escaping @Sendable () throws -> Data
  ) {
    self.directory = directory
    self.hardware = hardware
    self.nonce = nonce
  }
  public func load() async throws -> SharedLibraryWriterIdentity {
    let hardware = self.hardware
    let nonce = self.nonce
    let anchor = try await Task.detached(priority: .userInitiated) {
      let host = try hardware()
      guard !host.isEmpty else { throw SharedWriterIdentityError.hardwareUnavailable }
      let secret = try nonce()
      guard secret.count == 32 else { throw SharedWriterIdentityError.invalidNonce }
      return try SharedStateFingerprint.of(host + "\0" + secret.base64EncodedString())
    }.value
    try Task.checkCancellation()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var local = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try local.setResourceValues(values)
    let file = directory.appendingPathComponent("writer.json")
    return try await SharedLibraryWriterIdentityStore(file: file, installationAnchor: anchor).load()
  }
  private static func platformHardware() throws -> String {
    #if os(macOS)
      let service = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
      guard service != 0 else { throw SharedWriterIdentityError.hardwareUnavailable }
      defer { IOObjectRelease(service) }
      guard
        let raw = IORegistryEntryCreateCFProperty(
          service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
          as? String,
        !raw.isEmpty
      else { throw SharedWriterIdentityError.hardwareUnavailable }
      return raw
    #else
      // The iOS device-only item is the device binding. No vendor/account ID
      // or unavailable hardware-serial API is required by the shared core.
      return "device-only-keychain"
    #endif
  }
  private static func deviceNonce() throws -> Data {
    let authentication = LAContext()
    authentication.interactionNotAllowed = true
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "design.highgain.docktape.shared-libraries",
      kSecAttrAccount as String: "installation-nonce",
      kSecAttrSynchronizable as String: false,
      kSecUseAuthenticationContext as String: authentication,
    ]
    #if os(macOS)
      query[kSecUseDataProtectionKeychain as String] = true
    #endif
    func read() throws -> Data? {
      var request = query
      request[kSecReturnData as String] = true
      request[kSecMatchLimit as String] = kSecMatchLimitOne
      var result: CFTypeRef?
      let status = SecItemCopyMatching(request as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      guard status == errSecSuccess else { throw SharedWriterIdentityError.keychain(status) }
      guard let bytes = result as? Data, bytes.count == 32 else {
        throw SharedWriterIdentityError.invalidNonce
      }
      return bytes
    }
    if let existing = try read() { return existing }
    var bytes = [UInt8](repeating: 0, count: 32)
    let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard randomStatus == errSecSuccess else {
      throw SharedWriterIdentityError.keychain(randomStatus)
    }
    let secret = Data(bytes)
    var insertion = query
    insertion[kSecValueData as String] = secret
    insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(insertion as CFDictionary, nil)
    if status == errSecDuplicateItem, let existing = try read() { return existing }
    guard status == errSecSuccess else { throw SharedWriterIdentityError.keychain(status) }
    return secret
  }
}
