import Foundation
import Atomics

/// Handle for managing and cancelling an in-flight trace operation.
///
/// This class provides a thread-safe mechanism to cancel ongoing trace operations,
/// particularly useful when network conditions change or when the trace is no longer needed.
public final class TraceHandle: Sendable {
  private let _isCancelled = ManagedAtomic<Bool>(false)
  
  /// Whether this trace has been cancelled.
  public var isCancelled: Bool {
    _isCancelled.load(ordering: .acquiring)
  }
  
  /// Cancel this trace operation.
  ///
  /// Once cancelled, the trace will stop at the next cancellation check point
  /// and throw `TracerouteError.cancelled`.
  public func cancel() {
    _isCancelled.store(true, ordering: .releasing)
  }
  
  init() {}
}

// Extension to make TraceHandle Hashable for use in Set
extension TraceHandle: Hashable {
  public static func == (lhs: TraceHandle, rhs: TraceHandle) -> Bool {
    ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }
  
  public func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }
}