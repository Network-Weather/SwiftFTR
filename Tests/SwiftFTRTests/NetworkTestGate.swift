import Foundation

/// Async gate to serialize network-heavy tests and avoid cross-suite interference.
actor NetworkTestGate {
  static let shared = NetworkTestGate()

  private var permits: Int = 1
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func withPermit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T)
    async rethrows -> T
  {
    await acquire()
    defer { release() }
    return try await operation()
  }

  private func acquire() async {
    if permits > 0 {
      permits -= 1
      return
    }
    await withCheckedContinuation { cont in
      waiters.append(cont)
    }
  }

  private func release() {
    if let waiter = waiters.first {
      waiters.removeFirst()
      waiter.resume()
    } else {
      permits += 1
    }
  }
}
