//
//  AcceleratorBenchCatalog.swift
//  RunAnywhereAI
//
//  Turns the model registry into bench contenders, and maps a contender's
//  requested accelerator onto the SDK's load-time policy.
//
//  Split out of the runner so contender discovery can be tested without
//  standing up a runner, and because the runner had grown past the point where
//  one type should hold both orchestration and catalog rules.
//

import Foundation
import RunAnywhere

enum BenchCatalog {
    /// Every downloaded language model, as contenders.
    ///
    /// Built-ins are excluded: Apple's Foundation Models path is not a
    /// RunAnywhere engine and its numbers would not be ours to publish.
    static func availableContenders(from models: [RAModelInfo]) -> [BenchContender] {
        models
            .filter { model in
                guard model.category == .language, !model.isBuiltIn else { return false }
                if model.isDownloadedOnDisk { return true }
                // The registry marks a model downloaded before the artifact
                // probe catches up, so a non-empty local path counts too.
                return !model.localPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { BenchContender(model: $0) }
            .sorted { lhs, rhs in
                if lhs.accelerator == rhs.accelerator {
                    return lhs.displayName < rhs.displayName
                }
                // ANE first — it is the subject of the bench.
                return lhs.accelerator.sortRank < rhs.accelerator.sortRank
            }
    }

    /// Why the bench does not offer a CPU arm for llama.cpp.
    ///
    /// It tried. `LoadOptions.accelerator` exists in the public Swift API and
    /// takes `.cpu`, which would force llama.cpp off Metal and give the bench a
    /// genuine CPU contender. Passing it fails at load on SDK 0.20.35:
    ///
    ///     SDKException[configuration.invalidConfiguration]:
    ///     LoadOptions.accelerator cannot be carried by the native load ABI yet
    ///
    /// So the accelerator policy is declared but not wired through the native
    /// load ABI, and there is no route from this app to a CPU-only llama.cpp on
    /// Apple hardware — it offloads every layer to Metal
    /// (`offloaded 15/15 layers to GPU`, `device MTL0 (Apple A16 GPU)`).
    ///
    /// The consequence for the numbers: on Apple devices this bench compares
    /// the Neural Engine against the **GPU**, not against the CPU. That is the
    /// comparison the energy evidence is about anyway. Restore the CPU arm when
    /// the ABI carries the policy — until then, labelling anything here "CPU"
    /// would be a claim the runtime contradicts.
    static let acceleratorPolicyIsUnavailable = true
}
