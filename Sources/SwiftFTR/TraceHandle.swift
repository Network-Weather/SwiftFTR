import Foundation

/// Handle for managing and cancelling an in-flight trace operation.
///
/// This actor provides a thread-safe mechanism to cancel ongoing trace operations,
/// particularly useful when network conditions change or when the trace is no longer needed.
///
/// Uses Swift 6's actor isolation for thread safety.
public actor TraceHandle {
  private var _isCancelled = false

  /// Whether this trace has been cancelled.
  public var isCancelled: Bool {
    _isCancelled
  }

  /// Cancel this trace operation.
  ///
  /// Once cancelled, the trace will stop at the next cancellation check point
  /// and throw `TracerouteError.cancelled`.
  public func cancel() {
    _isCancelled = true
  }

  init() {}
}

// Extension to make TraceHandle Hashable for use in Set
extension TraceHandle: Hashable {
  nonisolated public static func == (lhs: TraceHandle, rhs: TraceHandle) -> Bool {
    ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }

  nonisolated public func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }
}
