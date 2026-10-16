import Dispatch
import Foundation
import Synchronization

/// A type that determines when `ValueObservation` notifies its fresh values.
///
/// ## Topics
///
/// ### Built-In Schedulers
///
/// - ``async(onQueue:)``
/// - ``immediate``
/// - ``mainActor``
/// - ``task``
/// - ``task(priority:)``
/// - ``AsyncValueObservationScheduler``
/// - ``TaskValueObservationScheduler``
public protocol ValueObservationScheduler: Sendable {
    /// Returns whether the initial value should be immediately notified.
    ///
    /// If the result is true, then this method was called on the main thread.
    func immediateInitialValue() -> Bool
    
    func schedule(_ action: @escaping @Sendable () -> Void)
}

extension ValueObservationScheduler {
    func scheduleInitial(_ action: @escaping @Sendable () -> Void) {
        if immediateInitialValue() {
            action()
        } else {
            schedule(action)
        }
    }
}

// MARK: - ValueObservationMainActorScheduler

/// A type that determines when `ValueObservation` notifies its fresh
/// values, on the main actor.
///
/// ## Topics
///
/// ### Built-In Schedulers
///
/// - ``immediate``
/// - ``ValueObservationScheduler/mainActor``
/// - ``ImmediateValueObservationScheduler``
/// - ``DelayedMainActorValueObservationScheduler``
public protocol ValueObservationMainActorScheduler: ValueObservationScheduler {
    func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void)
}

extension ValueObservationMainActorScheduler {
    public func schedule(_ action: @escaping @Sendable () -> Void) {
        scheduleOnMainActor(action)
    }
}

// MARK: - AsyncValueObservationScheduler

/// A scheduler that asynchronously notifies fresh value of a `DispatchQueue`.
public struct AsyncValueObservationScheduler: ValueObservationScheduler {
    var queue: DispatchQueue
    
    public init(queue: DispatchQueue) {
        self.queue = queue
    }
    
    public func immediateInitialValue() -> Bool { false }
    
    public func schedule(_ action: @escaping @Sendable () -> Void) {
        queue.async(execute: action)
    }
}

extension ValueObservationScheduler where Self == AsyncValueObservationScheduler {
    /// A scheduler that asynchronously notifies fresh value of the
    /// given `DispatchQueue`.
    ///
    /// For example:
    ///
    /// ```swift
    /// let observation = ValueObservation.tracking { db in
    ///     try Player.fetchAll(db)
    /// }
    ///
    /// let cancellable = try observation.start(
    ///     in: dbQueue,
    ///     scheduling: .async(onQueue: .main),
    ///     onError: { error in ... },
    ///     onChange: { (players: [Player]) in
    ///         print("fresh players: \(players)")
    ///     })
    /// ```
    ///
    /// - warning: Make sure you provide a serial queue, because a
    ///   concurrent one such as `DispachQueue.global(qos: .default)` would
    ///   mess with the ordering of fresh value notifications.
    public static func async(onQueue queue: DispatchQueue) -> AsyncValueObservationScheduler {
        AsyncValueObservationScheduler(queue: queue)
    }
}

// MARK: - ImmediateValueObservationScheduler

/// A scheduler that notifies all values on the main actor. The
/// first value is immediately notified when the `ValueObservation`
/// is started.
public struct ImmediateValueObservationScheduler: ValueObservationMainActorScheduler {
    public init() { }
    
    public func immediateInitialValue() -> Bool {
        GRDBPrecondition(
            Thread.isMainThread,
            "ValueObservation must be started from the main thread.")
        return true
    }
    
    public func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}

extension ValueObservationScheduler where Self == ImmediateValueObservationScheduler {
    /// A scheduler that notifies all values on the main actor. The
    /// first value is immediately notified when the `ValueObservation`
    /// is started.
    ///
    /// For example:
    ///
    /// ```swift
    /// let observation = ValueObservation.tracking { db in
    ///     try Player.fetchAll(db)
    /// }
    ///
    /// let cancellable = try observation.start(
    ///     in: dbQueue,
    ///     scheduling: .immediate,
    ///     onError: { error in ... },
    ///     onChange: { (players: [Player]) in
    ///         print("fresh players: \(players)")
    ///     })
    /// // <- here "fresh players" is already printed.
    /// ```
    ///
    /// - important: this scheduler requires that the observation is started
    ///  from the main actor. A fatal error is raised otherwise.
    public static var immediate: ImmediateValueObservationScheduler {
        ImmediateValueObservationScheduler()
    }
}

extension ValueObservationMainActorScheduler where Self == ImmediateValueObservationScheduler {
    /// A scheduler that notifies all values on the main actor. The
    /// first value is immediately notified when the `ValueObservation`
    /// is started.
    ///
    /// For example:
    ///
    /// ```swift
    /// let observation = ValueObservation.tracking { db in
    ///     try Player.fetchAll(db)
    /// }
    ///
    /// let cancellable = try observation.start(
    ///     in: dbQueue,
    ///     scheduling: .immediate,
    ///     onError: { error in ... },
    ///     onChange: { (players: [Player]) in
    ///         print("fresh players: \(players)")
    ///     })
    /// // <- here "fresh players" is already printed.
    /// ```
    ///
    /// - important: this scheduler requires that the observation is started
    ///  from the main actor. A fatal error is raised otherwise.
    public static var immediate: ImmediateValueObservationScheduler {
        ImmediateValueObservationScheduler()
    }
}

// MARK: - TaskValueObservationScheduler

/// A scheduler that notifies all values on the cooperative thread pool.
public final class TaskValueObservationScheduler: ValueObservationScheduler {
    typealias Action = @Sendable () -> Void
    let continuation: AsyncStream<Action>.Continuation
    let task: Task<Void, Never>
    
    init(priority: TaskPriority?) {
        let (stream, continuation) = AsyncStream.makeStream(of: Action.self)
        
        self.continuation = continuation
        self.task = Task(priority: priority) {
            for await action in stream {
                action()
            }
        }
    }
    
    deinit {
        task.cancel()
    }
    
    public func immediateInitialValue() -> Bool {
        false
    }
    
    public func schedule(_ action: @escaping @Sendable () -> Void) {
        continuation.yield(action)
    }
}

extension ValueObservationScheduler where Self == TaskValueObservationScheduler {
    /// A scheduler that notifies all values from a new `Task`.
    public static var task: TaskValueObservationScheduler {
        TaskValueObservationScheduler(priority: nil)
    }
    
    /// A scheduler that notifies all values from a new `Task` with the
    /// given priority.
    public static func task(priority: TaskPriority) -> TaskValueObservationScheduler {
        TaskValueObservationScheduler(priority: priority)
    }
}

// MARK: - DelayedMainActorValueObservationScheduler

/// A scheduler that notifies all values on the cooperative thread pool.
public final class DelayedMainActorValueObservationScheduler: ValueObservationMainActorScheduler {
    public func immediateInitialValue() -> Bool {
        false
    }
    
    public func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async(execute: action)
    }
}

extension ValueObservationScheduler where Self == DelayedMainActorValueObservationScheduler {
    /// A scheduler that notifies all values on the main actor.
    public static var mainActor: DelayedMainActorValueObservationScheduler {
        DelayedMainActorValueObservationScheduler()
    }
}

// MARK: - MainActorHopValueObservationScheduler

/// A scheduler that notifies all values on the main actor, in the order
/// `ValueObservation` scheduled them, without depending on `DispatchQueue.main`
/// being drained.
///
/// ``ValueObservationScheduler/mainActor`` delivers with
/// `DispatchQueue.main.async`, which runs only where something drains the main
/// queue. A process that installs its own main executor - so that `MainActor`
/// jobs run even though nothing drains that queue, as SwiftOmniUI's hosts do -
/// would never hear an observation again after its first value. This scheduler
/// keeps the ordering the `mainActor` scheduler promises - one action at a time,
/// in order, on the main actor - and hands the work over with
/// `Task { @MainActor }`, which any host that drains its own executor runs.
public final class MainActorHopValueObservationScheduler: ValueObservationMainActorScheduler, @unchecked Sendable {
    /// Guards `pending` and `delivering`. An action holds the lock only for as
    /// long as it takes to read the next one out: an action may schedule
    /// another, so none is ever run inside the lock.
    private let stateLock = Mutex(())
    private var pending: [@MainActor () -> Void] = []
    private var delivering = false

    public init() { }

    public func immediateInitialValue() -> Bool { false }

    public func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
        let startsDelivery = stateLock.withLock { _ -> Bool in
            pending.append(action)
            guard !delivering else { return false }
            delivering = true
            return true
        }
        if startsDelivery { hop() }
    }

    private func hop() {
        Task { @MainActor [self] in deliver() }
    }

    /// Delivers the actions waiting, in the order they were scheduled. A turn is
    /// bounded, so an uninterrupted flow of values hands the rest to the next
    /// turn instead of holding this one open.
    @MainActor
    private func deliver() {
        for _ in 0..<1024 {
            guard let action = take() else { return }
            action()
        }
        if hasWaiting() { hop() }
    }

    /// The next action in order, clearing the delivery flag when none is left.
    private func take() -> (@MainActor () -> Void)? {
        stateLock.withLock { _ -> (@MainActor () -> Void)? in
            if pending.isEmpty {
                delivering = false
                return nil
            }
            return pending.removeFirst()
        }
    }

    /// Whether an action is waiting, clearing the delivery flag when none is.
    private func hasWaiting() -> Bool {
        stateLock.withLock { _ -> Bool in
            if pending.isEmpty {
                delivering = false
                return false
            }
            return true
        }
    }
}

extension ValueObservationScheduler where Self == MainActorHopValueObservationScheduler {
    /// A scheduler that notifies all values on the main actor, by a
    /// `Task { @MainActor }` hop rather than by the main queue.
    public static var mainActorHop: MainActorHopValueObservationScheduler {
        MainActorHopValueObservationScheduler()
    }
}
