#if os(macOS) || targetEnvironment(macCatalyst)
import Dispatch

/// Starts the work for one connection's messages in the order the messages arrive, on one serial executor.
///
/// The connection's event handler runs on `queue`, and so does every job of this actor. Each message becomes a job;
/// `dispatch(_:)` queues the job and creates a task that starts the oldest queued job on this actor. Tasks that are
/// isolated to an actor are enqueued directly on that actor's executor, and the executor here is a serial dispatch
/// queue, which runs jobs strictly in the order they were enqueued, so jobs start in arrival order. A job that suspends
/// lets the next one start, which is the interleaving `NSXPCConnection` and XPC itself allow.
///
/// Why not a default actor: a default actor runs its jobs by priority, and XPC delivers each message at its sender's
/// quality of service, so messages from one sender could overtake each other. Why not `assumeIsolated` in the event
/// handler: before macOS 15 the runtime cannot tell that a dispatch block runs on an actor's queue, and traps.
internal actor MessageDispatcher {
    /// How a dispatcher runs its jobs, which depends on what the system provides.
    ///
    /// Everything but `automatic` exists so that tests on a new system can take the paths that older systems take.
    enum Strategy: Sendable, CaseIterable {
        /// The best the running system offers: `DispatchSerialQueue`'s own executor on macOS 14 and later, and
        /// `Task.immediate` to start jobs on macOS 26 and later.
        case automatic
        /// What macOS 14 through 25 do: `DispatchSerialQueue`'s own executor, and a task enqueued for every job.
        case serialQueueExecutor
        /// What macOS 12 and 13 do: `QueueExecutor`, and a task enqueued for every job.
        case queueExecutor
    }

    /// The serial queue that runs the connection's event handler and every job of this actor.
    nonisolated let queue: DispatchQueue

    /// The executor for systems where `DispatchSerialQueue` is not yet an executor; `nil` elsewhere.
    ///
    /// Kept here because `executor` does not retain it.
    private nonisolated let queueExecutor: QueueExecutor?

    /// The executor that runs this actor's jobs on `queue`.
    private nonisolated let executor: UnownedSerialExecutor

    /// Jobs whose messages have arrived but which have not started yet, oldest first.
    private nonisolated let pendingJobs = LockedState.make([Job]())

    /// Whether `dispatch(_:)` may start a job right away with `Task.immediate`.
    private nonisolated let startsJobsImmediately: Bool

    /// A unit of work to start on this actor's executor.
    struct Job: Sendable {
        /// Runs on the actor's executor, because nonisolated async closures run on their caller's executor.
        let run: @Sendable () async -> Void
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        self.executor
    }

    init(label: String, strategy: Strategy = .automatic) {
        if #available(macOS 14.0, macCatalyst 17.0, *), strategy != .queueExecutor {
            let queue = DispatchSerialQueue(label: label)
            self.queue = queue
            self.queueExecutor = nil
            self.executor = queue.asUnownedSerialExecutor()
        } else {
            let queue = DispatchQueue(label: label)
            let queueExecutor = QueueExecutor(queue: queue)
            self.queue = queue
            self.queueExecutor = queueExecutor
            self.executor = queueExecutor.asUnownedSerialExecutor()
        }

        self.startsJobsImmediately = strategy == .automatic
    }

    /// Queues `job` and arranges for it to start on this actor, after every job dispatched before it has started.
    nonisolated func dispatch(_ job: Job) {
        self.pendingJobs.withLock { $0.append(job) }

        if #available(macOS 26.0, macCatalyst 26.0, *), self.startsJobsImmediately {
            // From the event handler, which runs on `queue`, this starts the job right away instead of enqueuing it
            // behind the event handler. Anywhere else it enqueues the task like `Task(operation:)` would.
            Task.immediate(operation: self.startOldestJob)
        } else {
            Task(operation: self.startOldestJob)
        }
    }

    private func startOldestJob() async {
        let job = self.pendingJobs.withLock { pendingJobs in
            pendingJobs.isEmpty ? nil : pendingJobs.removeFirst()
        }

        await job?.run()
    }
}

/// Runs an actor's jobs on a serial dispatch queue, for systems where `DispatchSerialQueue` is not yet an executor.
internal final class QueueExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ job: UnownedJob) {
        let executor = self.asUnownedSerialExecutor()

        self.queue.async {
            job.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(self.queue))
    }
}
#endif
