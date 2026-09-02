//
//  CpuLoadGenerator.swift
//  RunAnywhereAI
//
//  Saturates the general-purpose cores so the Contention panel can ask the one
//  question that separates "planned onto the Neural Engine" from "actually
//  executing there": change the machine's CPU load and re-time the same work.
//
//  A path really on the ANE is a separate engine and barely notices. A path on
//  the CPU competes for the very cores this class is stealing. That difference
//  is the whole reason the ANE plane exists, and it needs no `sudo`, no
//  `powermetrics` and no privileged API to demonstrate.
//

import Foundation

/// Runs N spinning threads until stopped.
///
/// `@unchecked Sendable` is deliberate: the only shared mutable state is
/// `isRunning`, and every access to it goes through `lock`.
final class CpuLoadGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = false
    private var threads: [Thread] = []
    /// CPU seconds each spinner has burned, published as it goes.
    ///
    /// This exists because `getrusage(RUSAGE_SELF)` is process-wide: it counts
    /// these threads too. Reporting it unadjusted would charge the load
    /// generator's own burn to the generation being measured, which showed up
    /// on a 6-core phone as an inference holding "4.36 cores" while the
    /// accelerator did the arithmetic. The runner subtracts this.
    private var threadCpuSeconds: [Double] = []

    /// Half the cores: "the app is busy", not "the machine is wedged".
    ///
    /// `cores - 1` was the first default and it is the wrong question on a
    /// phone. An accelerator still needs the host to sample, detokenize and
    /// dispatch between calls, so pinning 5 of 6 cores starves that leg and
    /// measures scheduler starvation rather than accelerator independence —
    /// on an iPhone 15 it cost the ANE path 58%, against −0.015% for the same
    /// experiment on a 10+ core Mac.
    ///
    /// Half the cores leaves the host leg able to run while still putting real
    /// pressure on anything doing its arithmetic on the CPU, which is the
    /// comparison this panel exists to make. The slider goes to 2x cores for a
    /// deliberate worst case, and every result states the thread count it was
    /// measured at.
    static var defaultThreadCount: Int {
        max(1, HostCostSampler.coreCount / 2)
    }

    static var maximumThreadCount: Int {
        max(1, HostCostSampler.coreCount * 2)
    }

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    /// Start `count` spinning threads. No-op if already running.
    func start(threadCount count: Int) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        let threadCount = max(1, count)
        lock.lock()
        threadCpuSeconds = Array(repeating: 0, count: threadCount)
        lock.unlock()

        var started: [Thread] = []
        for index in 0..<threadCount {
            let thread = Thread { [weak self] in
                Self.spin(
                    while: { self?.running ?? false },
                    publishCpu: { [weak self] seconds in
                        self?.publish(cpuSeconds: seconds, forThread: index)
                    }
                )
            }
            thread.name = "AcceleratorBench.load.\(index)"
            // .userInitiated rather than .userInteractive: high enough to hold
            // real cores, not high enough to preempt the main thread and make
            // the app itself look like the problem.
            thread.qualityOfService = .userInitiated
            thread.start()
            started.append(thread)
        }

        lock.lock()
        threads = started
        lock.unlock()
    }

    func stop() {
        lock.lock()
        isRunning = false
        threads.removeAll()
        lock.unlock()
    }

    /// Total CPU seconds the load threads have burned since `start`.
    ///
    /// Read this while the load is still running, or immediately after
    /// `stop()`; the counters are not cleared until the next `start`.
    var consumedCpuSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return threadCpuSeconds.reduce(0, +)
    }

    private func publish(cpuSeconds: Double, forThread index: Int) {
        lock.lock()
        if threadCpuSeconds.indices.contains(index) {
            threadCpuSeconds[index] = cpuSeconds
        }
        lock.unlock()
    }

    /// This thread's own consumed CPU time.
    ///
    /// Per-thread accounting is the only way to attribute CPU inside a process
    /// that is deliberately burning it in two places at once. POSIX's
    /// `pthread_getcpuclockid` does not exist on Darwin, so this goes through
    /// Mach's `thread_info`, which reports user and system time for one thread.
    private static func currentThreadCpuSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let thread = mach_thread_self()
        // mach_thread_self() returns a send right that leaks without this.
        defer { mach_port_deallocate(mach_task_self_, thread) }

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = Double(info.user_time.seconds)
            + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds)
            + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    /// Integer-and-float busy work the optimiser cannot fold away.
    ///
    /// `accumulator` is read through `blackHole` so the loop has an observable
    /// effect; without that, `-O` deletes the body and the "load" threads sleep
    /// at 0% while the panel reports a contention result of zero.
    private static func spin(
        while shouldContinue: @escaping () -> Bool,
        publishCpu: @escaping (Double) -> Void
    ) {
        var accumulator = 1.000001
        var counter: UInt64 = 0
        while shouldContinue() {
            // A batch between condition checks: the check itself takes a lock,
            // and taking it every iteration would measure lock contention
            // instead of CPU saturation.
            for _ in 0..<20_000 {
                counter = counter &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                accumulator = (accumulator * 1.0000001 + Double(counter & 0xFF)).squareRoot() + 1
            }
            blackHole(accumulator + Double(counter & 1))
            publishCpu(currentThreadCpuSeconds())
        }
        publishCpu(currentThreadCpuSeconds())
    }

    @inline(never)
    private static func blackHole(_ value: Double) {
        // Reading the value into a volatile-ish sink. `withExtendedLifetime`
        // keeps the compiler from proving the computation dead.
        withExtendedLifetime(value) {}
    }
}
