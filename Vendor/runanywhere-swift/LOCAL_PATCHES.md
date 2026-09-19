# Vendored runanywhere-swift (local patches, not upstream)

- Upstream: https://github.com/RunanywhereAI/runanywhere-swift
- Pinned revision: 8bd75a291dee4c359a2c118ee317ab8c33dd0238 (version 0.20.34,
  matching the app's mlx-swift-lm 3.31.5 / mlx-swift 0.31.8 pins)
- `.git` removed intentionally so this repo stays self-contained.

Local patches (all in `Sources/`):
1. `MLXRuntime/PrismHadamardQwen35.swift` (new) — loads PrismML
   Ternary-Bonsai-2 MLX packs (`model_type: prism_hadamard_qwen35`) by
   swapping the 402 packed projections for Hadamard-aware quantized layers
   (port of the pack's `runtime/runtime.py`). Registered in both the VLM
   and LLM model-type registries.
2. `MLXRuntime/MLX.swift` — calls `registerPrismHadamardQwen35ModelTypes()`
   in the `.llm` and `.vlm` load paths (next to the Nemotron registration).
3. `RunAnywhere/.../TTSNamespace.swift` + `RunAnywhere/.../VoiceAgentMicDriver.swift` —
   MainActor-isolation annotations so the sources compile under Xcode 27
   (Swift 6.4), which newly infers `AudioPlaybackManager` as `@MainActor`
   via `@Published`. Voice runtime behavior is unchanged on the happy path,
   but treat voice as best-effort on this toolchain.
