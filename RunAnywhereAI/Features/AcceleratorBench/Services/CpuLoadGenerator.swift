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

    /// Sensible default: leave one core for the app's own main thread and the
    /// SDK's orchestration, so the CPU contender is starved rather than the
    /// UI frozen. On the ANE path this still leaves the ANE completely free,
    /// which is exactly the asymmetry being measured.
    static var defaultThreadCount: Int {
        max(1, HostCostSampler.coreCount - 1)
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

        var started: [Thread] = []
        for index in 0..<max(1, count) {
            let thread = Thread { [weak self] in
                Self.spin { self?.running ?? false }
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

    /// Integer-and-float busy work the optimiser cannot fold away.
    ///
    /// `accumulator` is read through `blackHole` so the loop has an observable
    /// effect; without that, `-O` deletes the body and the "load" threads sleep
    /// at 0% while the panel reports a contention result of zero.
    private static func spin(_ shouldContinue: @escaping () -> Bool) {
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
        }
    }

    @inline(never)
    private static func blackHole(_ value: Double) {
        // Reading the value into a volatile-ish sink. `withExtendedLifetime`
        // keeps the compiler from proving the computation dead.
        withExtendedLifetime(value) {}
    }
}
