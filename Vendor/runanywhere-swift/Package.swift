// swift-tools-version: 6.2
import PackageDescription

// =============================================================================
// RunAnywhere Swift SDK — standalone SPM distribution
// =============================================================================
//
// This repository is GENERATED from the RunanywhereAI/runanywhere-sdks
// monorepo. Do not hand-edit; open PRs against the monorepo instead:
//
//   monorepo Package.swift          → this Package.swift
//   monorepo bindings/swift/Sources → Sources/
//
// WHY THIS REPO EXISTS
//   `.package(url: ".../runanywhere-sdks", from: "…")` makes SwiftPM clone the
//   entire monorepo (C++ core, every engine, all five language bindings) just
//   to compile a Swift package that needs only Sources/ plus remote binary
//   targets. This repo carries the Swift surface and nothing else.
//
// CONSUMPTION
//   .package(url: "https://github.com/RunanywhereAI/runanywhere-swift.git",
//            from: "0.20.17")
//
//   Products:
//     RunAnywhere          — core SDK (required)
//     RunAnywhereLlamaCPP  — llama.cpp LLM + VLM
//     RunAnywhereONNX      — embeddings + Sherpa-ONNX STT/TTS/VAD + CoreML diffusion
//     RunAnywhereMLX       — Apple MLX LLM/VLM/embeddings/STT/TTS
//     RunAnywhereNeuRT     — Apple Neural Engine LLM + CoreML diffusion
//
// BINARIES
//   The XCFrameworks are NOT vendored here. They are the checksum-verified
//   release archives already attached to the matching runanywhere-sdks GitHub
//   release, downloaded by SwiftPM on resolve.
//
// ⚠️  NEVER introduce a `revision:` or `branch:` dependency pin below.
//   SwiftPM refuses to resolve a package *by version* when its own manifest
//   pins any dependency to a revision or branch — a single revision pin makes
//   `from: "0.20.17"` unresolvable for every consumer of this package. The two
//   MLX dependencies are therefore consumed from RunanywhereAI mirrors by
//   `exact:` version. See the comments on each below.
//
// =============================================================================

// Version of the remote XCFramework release archives on runanywhere-sdks.
// Kept in lockstep with this repo's git tag by the monorepo release tooling
// (bindings/swift/scripts/sync-checksums.sh).
let sdkVersion = "0.20.34"

let binaryBaseURL =
    "https://github.com/RunanywhereAI/runanywhere-sdks/releases/download/v\(sdkVersion)"

// mlx-audio-swift enables the MLX STT/TTS/VAD and speaker-diarization provider
// plumbing. It requires a Swift 6.2+ toolchain and upstream has not cut a tag
// compatible with mlx-swift-lm 3.x, so one specific upstream commit is needed.
//
// That commit used to be consumed with `revision:`, which made this package
// unresolvable via `from:` (see the warning above). It is therefore mirrored
// into RunanywhereAI — we control that org; upstream is pull-only for us — with
// the EXACT same commit tagged so it can be consumed by version:
//
//   https://github.com/RunanywhereAI/mlx-audio-swift  tag 0.1.5
//       == Blaizzy/mlx-audio-swift @ 580e952adda0cd6bdc5c04f402822adbb61525c8
//
// The tag number is fork-local bookkeeping, NOT upstream 0.1.5 — the commit
// predates upstream v0.1.3. `.exact` keeps resolution byte-identical to the old
// revision pin.
let mlxAudioPackageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/RunanywhereAI/mlx-audio-swift.git", exact: "0.1.5"),
]
let mlxAudioRuntimeDependencies: [Target.Dependency] = [
    .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
    .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
    .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
]

// PrismML's Bonsai 1-bit weights need kernels absent from upstream mlx-swift.
// PrismML-Eng/mlx-swift is the maintained Prism delta, keeping mlx-swift-lm
// 3.31.x API-compatible while enabling bits=1 / group_size=128 models.
// Consumed by version rather than `revision:` for the same reason as
// mlx-audio-swift above, through our mirror:
//
//   https://github.com/RunanywhereAI/mlx-swift  tag 0.31.8
//       == 7bf45022ebfe22c20b14b0d648451dbdf5e66bf4
//
// 0.31.8 is fork-local bookkeeping, NOT an upstream ml-explore release. It is
// deliberately a version that exists ONLY in our mirror: the `mlx-swift`
// package identity is shared with ml-explore/mlx-swift, so a fork-only
// version fails loudly instead of silently resolving to upstream without the
// Prism 1-bit kernels. Keep this in lockstep with runAnywhereMLXSwiftVersion
// in the monorepo's root Package.swift — this dist repo's manifest is
// manually maintained, NOT auto-generated from root, so it can drift silently
// if a dependency bump here is forgotten (this exact drift broke the 0.20.24
// tag for ~40 minutes before being caught and fixed).
let prismMLXSwiftVersion: Version = "0.31.8"

let package = Package(
    name: "runanywhere-swift",
    platforms: [
        .iOS("17.5"),
        .macOS("14.5"),
    ],
    products: [
        // =================================================================
        // Core SDK — always needed
        // =================================================================
        .library(
            name: "RunAnywhere",
            type: .static,
            targets: ["RunAnywhere"]
        ),

        // =================================================================
        // LlamaCPP Backend — LLM text generation + VLM
        // =================================================================
        .library(
            name: "RunAnywhereLlamaCPP",
            type: .static,
            targets: ["LlamaCPPRuntime"]
        ),

        // =================================================================
        // ONNX Runtime Backend — embeddings + Sherpa STT/TTS/VAD
        // =================================================================
        .library(
            name: "RunAnywhereONNX",
            type: .static,
            targets: ["ONNXRuntime"]
        ),

        // =================================================================
        // MLX Backend — Apple MLX LLM/VLM/embedding/STT/TTS
        // =================================================================
        .library(
            name: "RunAnywhereMLX",
            type: .static,
            targets: ["MLXRuntime"]
        ),

        // =================================================================
        // NeuRT Backend — Apple Neural Engine LLM + CoreML diffusion
        // =================================================================
        .library(
            name: "RunAnywhereNeuRT",
            type: .static,
            targets: ["NeuRTRuntime"]
        ),
    ],
    dependencies: [
        // SPM deps use `.upToNextMinor` (not open-ended `from:`) so a silent
        // upstream major bump can't land in `Package.resolved` without a
        // Package.swift edit. Floors are mirrored in
        // Sources/RunAnywhere/Generated/Versions.swift (RAVersions).
        .package(url: "https://github.com/apple/swift-crypto.git", .upToNextMinor(from: "3.15.1")),
        .package(url: "https://github.com/JohnSundell/Files.git", .upToNextMinor(from: "4.3.0")),
        .package(url: "https://github.com/devicekit/DeviceKit.git", .upToNextMinor(from: "5.8.0")),
        // swift-protobuf backs the idl/*.proto generated types under
        // Sources/RunAnywhere/Generated/*.pb.swift.
        .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMinor(from: "1.38.0")),
        .package(
            url: "https://github.com/RunanywhereAI/mlx-swift.git",
            exact: prismMLXSwiftVersion
        ),
        // Must be the RunanywhereAI fork, exact version, matching root
        // Package.swift's runAnywhereMLXSwiftLMVersion — see the drift note
        // above prismMLXSwiftVersion. Pointing this at unforked upstream
        // ml-explore/mlx-swift-lm (as this line previously did) fails to
        // resolve MLXRuntime's use of Generation.rejectedToolCall /
        // RejectedToolCallError, which only exist in the fork.
        .package(url: "https://github.com/RunanywhereAI/mlx-swift-lm.git", exact: "3.31.5"),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.3.0")),
    ] + mlxAudioPackageDependencies,
    targets: [
        // =================================================================
        // C Bridge Module — Core Commons
        //
        // The headers under Sources/RunAnywhere/CRACommons/include are thin
        // forwarding shims that `#include "rac/…"`. Those canonical headers
        // ship inside RACommons.xcframework (every slice carries a Headers/rac
        // tree), and SwiftPM puts the resolved slice's Headers directory on the
        // include path via the RACommonsBinary dependency. The monorepo
        // manifest additionally points at its in-tree `core/include` because
        // the source tree is present there; this distribution has no source
        // tree, which is exactly the "package-only build" case the shims
        // document.
        // =================================================================
        .target(
            name: "CRACommons",
            dependencies: ["RACommonsBinary"],
            path: "Sources/RunAnywhere/CRACommons",
            publicHeadersPath: "include"
        ),

        // =================================================================
        // C Bridge Module — LlamaCPP Backend Headers
        // =================================================================
        .target(
            name: "LlamaCPPBackend",
            dependencies: [
                "CRACommons",
                "RABackendLlamaCPPBinary",
            ],
            path: "Sources/LlamaCPPRuntime/include",
            publicHeadersPath: "."
        ),

        // =================================================================
        // C Bridge Module — ONNX Backend Headers
        //
        // ONNX Runtime is statically linked into RABackendONNX (v0.19.0+).
        // Sherpa-ONNX ships as a peer xcframework owning the STT (Whisper /
        // Zipformer / Paraformer), TTS (Piper / VITS) and VAD (Silero)
        // primitives under `framework == .sherpa`; ONNX owns embeddings and
        // generic ONNX Runtime services under `framework == .onnx`. Both must
        // be linked so the unified plugin router can resolve either at load.
        // =================================================================
        .target(
            name: "ONNXBackend",
            dependencies: [
                "CRACommons",
                "RABackendONNXBinary",
                "RABackendSherpaBinary",
            ],
            path: "Sources/ONNXRuntime/include",
            publicHeadersPath: "."
        ),

        // =================================================================
        // C Bridge Module — NeuRT Backend Headers
        // =================================================================
        .target(
            name: "NeuRTBackend",
            dependencies: [
                "CRACommons",
                "RABackendNeuRTBinary",
            ],
            path: "Sources/NeuRTRuntime/include",
            publicHeadersPath: "."
        ),

        // =================================================================
        // C Bridge Module — MLX Backend Headers
        // =================================================================
        .target(
            name: "MLXBackend",
            dependencies: [
                "CRACommons",
                "RABackendMLXBinary",
            ],
            path: "Sources/MLXRuntime/include",
            publicHeadersPath: "."
        ),

        // =================================================================
        // Core SDK
        // =================================================================
        .target(
            name: "RunAnywhere",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Files", package: "Files"),
                .product(name: "DeviceKit", package: "DeviceKit"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                "CRACommons",
                "RACommonsBinary",
            ],
            path: "Sources/RunAnywhere",
            exclude: [
                // Declared as its own sibling target above; excluded here to
                // avoid a double compile.
                "CRACommons",
                // Emitted by codegen but has zero consumers in the Swift SDK.
                // `diffusion_options.pb.swift` is deliberately NOT excluded —
                // the CoreML Stable-Diffusion facade consumes it.
                "Generated/router.pb.swift",
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [
                .define("SWIFT_PACKAGE"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedFramework("CFNetwork"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),

        // =================================================================
        // LlamaCPP Runtime Backend
        // =================================================================
        .target(
            name: "LlamaCPPRuntime",
            dependencies: [
                "RunAnywhere",
                "LlamaCPPBackend",
                "RABackendLlamaCPPBinary",
            ],
            path: "Sources/LlamaCPPRuntime",
            exclude: ["include", "README.md"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),

        // =================================================================
        // ONNX Runtime Backend
        //
        // Depends on RABackendONNXBinary (embeddings + Silero VAD) and
        // RABackendSherpaBinary (Sherpa-ONNX STT/TTS/VAD). `ONNX.register()`
        // plumbs both plugins into the commons plugin registry at SDK boot.
        // Also carries RABackendNeuRTBinary: `ONNX.register()` bundles the
        // Apple secondary backends, and this target already links CoreML +
        // Accelerate, so it is the natural home for the diffusion engine
        // archive. The coreml plugin auto-wins the DIFFUSION slot once linked.
        // =================================================================
        .target(
            name: "ONNXRuntime",
            dependencies: [
                "RunAnywhere",
                "ONNXBackend",
                "RABackendONNXBinary",
                "RABackendSherpaBinary",
                "RABackendNeuRTBinary",
            ],
            path: "Sources/ONNXRuntime",
            exclude: ["include", "README.md"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
                .linkedLibrary("archive"),
                .linkedLibrary("bz2"),
            ]
        ),

        // =================================================================
        // NeuRT Runtime Backend — Apple Neural Engine LLM + CoreML diffusion
        //
        // Links RABackendNeuRTBinary and registers the `neurt` engine plugin
        // via `NeuRT.register()`. NeuRT is also bundled into ONNXRuntime (so
        // existing ONNX/diffusion consumers are unaffected); this standalone
        // product lets consumers opt into NeuRT directly.
        // =================================================================
        .target(
            name: "NeuRTRuntime",
            dependencies: [
                "RunAnywhere",
                "NeuRTBackend",
                "RABackendNeuRTBinary",
            ],
            path: "Sources/NeuRTRuntime",
            exclude: ["include"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML"),
            ]
        ),

        // =================================================================
        // MLX Runtime Backend
        // =================================================================
        .target(
            name: "MLXRuntime",
            dependencies: [
                "MLXBackend",
                "RABackendMLXBinary",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ] + mlxAudioRuntimeDependencies,
            path: "Sources/MLXRuntime",
            exclude: ["include"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),

        // =================================================================
        // Binary targets — checksum-verified release archives downloaded from
        // the matching runanywhere-sdks GitHub release. All xcframeworks carry
        // iOS device + iOS simulator + macOS slices (v0.19.0+).
        //
        // Checksums are written by the monorepo's
        // bindings/swift/scripts/sync-checksums.sh at release time and must
        // match the archives attached to v<sdkVersion> exactly.
        // =================================================================
        .binaryTarget(
            name: "RACommonsBinary",
            url: "\(binaryBaseURL)/RACommons-ios-v\(sdkVersion).zip",
            checksum: "ff8fa398180b57f26827044edf7afd0bbde30057880842ca2bc25f3f325a8c6d"
        ),
        .binaryTarget(
            name: "RABackendLlamaCPPBinary",
            url: "\(binaryBaseURL)/RABackendLLAMACPP-ios-v\(sdkVersion).zip",
            checksum: "baab28bbe22de196b9442cb17895142b2a8a80fa951c8a796bf4d4eb3256e9c6"
        ),
        .binaryTarget(
            name: "RABackendONNXBinary",
            url: "\(binaryBaseURL)/RABackendONNX-ios-v\(sdkVersion).zip",
            checksum: "33aa8ebe41cfa07abdb55e1bfd693fadcfa1645a4aaf592e1222171de0323961"
        ),
        .binaryTarget(
            name: "RABackendSherpaBinary",
            url: "\(binaryBaseURL)/RABackendSherpa-ios-v\(sdkVersion).zip",
            checksum: "64955f767e0302ced5f9b9283d48cf37a7c8d1a77fc066712ffdf471ee9715cc"
        ),
        .binaryTarget(
            name: "RABackendNeuRTBinary",
            url: "\(binaryBaseURL)/RABackendNeuRT-ios-v\(sdkVersion).zip",
            checksum: "7fceb9ce9470c73cffa7db4193b6915da3e3df8695fe01b82f0b6a065224879e"
        ),
        .binaryTarget(
            name: "RABackendMLXBinary",
            url: "\(binaryBaseURL)/RABackendMLX-ios-v\(sdkVersion).zip",
            checksum: "c0fa8f3b5312e699c0bc37c648a4bcf0ff6b4634af1c874b74daf5aacc18e345"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
