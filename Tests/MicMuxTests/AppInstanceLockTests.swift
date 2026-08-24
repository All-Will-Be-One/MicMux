import Foundation
import XCTest

@testable import MicMux

/// Protects the invariant that installed and project app copies share one audio graph.
final class AppInstanceLockTests: XCTestCase {
  func test_a_second_lock_holder_is_refused_until_the_primary_releases_it() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let lockURL = directory.appendingPathComponent("instance.lock")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var primary: AppInstanceLock? = AppInstanceLock(url: lockURL)
    XCTAssertTrue(try XCTUnwrap(primary).isPrimary)

    let duplicate = AppInstanceLock(url: lockURL)
    XCTAssertFalse(duplicate.isPrimary)

    primary = nil
    let replacement = AppInstanceLock(url: lockURL)
    XCTAssertTrue(replacement.isPrimary)
  }
}
