import AppKit
import Darwin
import Foundation

/// Holds a process-scoped file lock so project and installed app copies cannot run together.
final class AppInstanceLock {
  private let fileDescriptor: Int32
  let isPrimary: Bool

  init(url: URL = AppInstanceLock.defaultURL) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    fileDescriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    isPrimary = fileDescriptor < 0 || flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0
  }

  func activatePrimaryInstance() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let primary = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first { $0.processIdentifier != currentPID }
    _ = primary?.activate(options: [.activateAllWindows])
  }

  deinit {
    guard fileDescriptor >= 0 else { return }
    if isPrimary { flock(fileDescriptor, LOCK_UN) }
    close(fileDescriptor)
  }

  private static var defaultURL: URL {
    let applicationSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return
      applicationSupport
      .appendingPathComponent("MicMux", isDirectory: true)
      .appendingPathComponent("instance.lock")
  }
}
