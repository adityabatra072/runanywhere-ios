# RunAnywhere Swift SDK

On-device AI for iOS and macOS — LLM, VLM, speech-to-text, text-to-speech, VAD,
embeddings, reranking, RAG, diarization, segmentation, and diffusion, running
locally on the user's device.

This repository is the **lightweight SwiftPM distribution** of the RunAnywhere
Swift SDK. It carries the Swift sources and a manifest that pulls
checksum-verified native binaries from GitHub Releases — nothing else. Adding it
as a dependency does not clone the C++ core, the other four language bindings,
or the engine sources.

> **Generated repository.** The canonical source lives in
> [RunanywhereAI/runanywhere-sdks](https://github.com/RunanywhereAI/runanywhere-sdks).
> Open issues and pull requests there. Changes made directly here are overwritten
> on the next release.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/RunanywhereAI/runanywhere-swift.git", from: "0.20.34"),
]
```

Then depend on the core product plus whichever backends you need:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "RunAnywhere", package: "runanywhere-swift"),
        .product(name: "RunAnywhereLlamaCPP", package: "runanywhere-swift"),
    ]
)
```

In Xcode: **File → Add Package Dependencies…** and paste the URL above.

## Products

| Product | Adds | Engine |
|---|---|---|
| `RunAnywhere` | Core SDK — required by every backend | — |
| `RunAnywhereLlamaCPP` | LLM text generation, VLM | llama.cpp |
| `RunAnywhereONNX` | Embeddings, STT, TTS, VAD, CoreML diffusion | ONNX Runtime + Sherpa-ONNX |
| `RunAnywhereMLX` | LLM, VLM, embeddings, STT, TTS on Apple Silicon | Apple MLX |
| `RunAnywhereNeuRT` | Apple Neural Engine LLM, CoreML diffusion | NeuRT |

Backends are additive: link only what you use and the linker drops the rest.
`RunAnywhereONNX` also bundles the NeuRT/CoreML diffusion engine.

## Requirements

- iOS 17.5+ / macOS 14.5+
- Swift 6.2+ (Xcode 26+)

## Usage

```swift
import RunAnywhere
import RunAnywhereLlamaCPP

// Phase 1 — synchronous, registers platform services.
try RunAnywhere.initialize(apiKey: "…", environment: .production)

// Register the backends you linked.
LlamaCPP.register()

// Phase 2 — async: authenticate, register device, discover local models.
try await RunAnywhere.completeServicesInitialization()

// Generate.
let result = try await RunAnywhere.llm.generate(
    prompt: "Explain on-device inference in one sentence."
)
print(result.text)
```

Streaming, speech, and every other modality follow the same shape — one entry
point per feature on the `RunAnywhere` namespace. See the
[monorepo documentation](https://github.com/RunanywhereAI/runanywhere-sdks) for
the full API surface.

## Native binaries

The manifest declares remote `binaryTarget`s pointing at the release archives
attached to the matching `runanywhere-sdks` tag:

| XCFramework | Contents |
|---|---|
| `RACommons` | C++ core — all AI business logic behind the `rac_*` C ABI |
| `RABackendLLAMACPP` | llama.cpp LLM + VLM engine |
| `RABackendONNX` | ONNX Runtime embeddings (ORT statically linked) |
| `RABackendSherpa` | Sherpa-ONNX STT / TTS / VAD |
| `RABackendNeuRT` | Apple Neural Engine LLM + CoreML diffusion |
| `RABackendMLX` | Apple MLX engine |

Each ships iOS device, iOS simulator, and macOS arm64 slices, and each is
pinned by SHA-256 in `Package.swift`. SwiftPM downloads and verifies them on
`swift package resolve`.

## Versioning

This repository's tags track the RunAnywhere SDK version exactly. Tag `0.20.34`
here consumes the binaries from `runanywhere-sdks` release `v0.20.34`.

## License

See [LICENSE](LICENSE).
