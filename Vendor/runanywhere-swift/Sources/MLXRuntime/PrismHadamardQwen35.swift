//
//  PrismHadamardQwen35.swift
//  MLXRuntime Module
//
//  Local-only support for PrismML's Ternary-Bonsai-2 MLX packs
//  (`model_type: prism_hadamard_qwen35`, e.g.
//  `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit`).
//
//  The pack stores ternary language weights in a blockwise Hadamard-rotated
//  basis (2-bit group-128 affine containers, FP16 group scales). The matching
//  transform must be applied to activations at runtime: a forward FWHT before
//  every packed projection, and an inverse FWHT after the packed embedding
//  lookup. Loading the tensors as a plain `qwen3_5` checkpoint silently
//  produces wrong output, so this file registers the model type explicitly
//  and swaps the 402 packed projections for Hadamard-aware quantized layers
//  before weights are applied.
//
//  Port of the reference Python loader shipped inside the pack
//  (`runtime/runtime.py` + `runtime/artifact.py`):
//    - fwht(x): float32 cast, optional pre-signs, normalized Sylvester-Walsh-
//      Hadamard over blocks of 1024, optional post-signs, cast back.
//    - Linear:  y = quantized_matmul(fwht(x), W)   (affine, g128, 2-bit)
//    - Embed:   y = inverse_fwht(dequantize(W[idx]))
//
//  The per-tensor `signs` vectors and FP16 scales/biases are stored in the
//  safetensors itself (`<path>.signs`), so no `hadamard.json` parsing is
//  needed at load time; `config.json`'s `modules` list drives the swap.
//
//  NOTE: local patch only — not pushed anywhere.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM

// MARK: - Pack metadata (extra keys in the pack's config.json)

/// One entry of the pack's top-level `modules` array.
struct PrismHadamardModuleMeta: Codable, Sendable {
    var path: String
    var block: Int
    var embedding: Bool
    var dtype: String
}

/// The Prism-specific subset of the pack's `config.json`.
struct PrismHadamardPackMeta: Codable, Sendable {
    var modules: [PrismHadamardModuleMeta]
}

// MARK: - Forward / inverse block Hadamard transform

/// Normalized block FWHT with explicit ±1 signs, mirroring `runtime.py::fwht`.
///
/// Forward (`inverse == false`):  H((x * s) / sqrt(B))
/// Inverse (`inverse == true`):   (H(x / sqrt(B))) * s
func prismHadamardTransform(
    _ x: MLXArray, block: Int, signs: MLXArray, inverse: Bool, dtype: DType
) -> MLXArray {
    let shape = x.shape
    precondition(shape.last! % block == 0, "Hadamard block must divide last dim")
    var h = x.asType(.float32)
    if !inverse {
        h = h * signs
    }
    h = hadamardTransform(h.reshaped([-1, block]), scale: 1.0 / Float(block).squareRoot())
        .reshaped(shape)
    if inverse {
        h = h * signs
    }
    return h.asType(dtype)
}

// MARK: - Hadamard-aware quantized layers

/// Drop-in replacement for a packed projection: applies the forward FWHT to
/// the activations, then the stock 2-bit group-128 affine quantized matmul.
///
/// `signs` is declared as a plain parameter so the `<path>.signs` tensor in
/// the safetensors maps onto it during `update(parameters:)`, exactly like
/// `scales`/`biases` on `QuantizedLinear`.
final class PrismHadamardQuantizedLinear: QuantizedLinear {
    let signs: MLXArray
    let hadamardBlock: Int
    let computeDtype: DType

    init(_ other: Linear, block: Int, dtype: DType) {
        let outDim = other.weight.dim(0)
        let inDim = other.weight.dim(1)
        precondition(inDim % 128 == 0, "packed width must be a multiple of 128")
        self.hadamardBlock = block
        self.computeDtype = dtype
        // Placeholders with the exact stored shapes; values are overwritten
        // in place by `update(parameters:)` at load time.
        self.signs = MLXArray.ones([inDim])
        super.init(
            weight: MLXArray.zeros([outDim, inDim / 16], dtype: .uint32),
            bias: other.bias,
            scales: MLXArray.zeros([outDim, inDim / 128], dtype: .float16),
            biases: MLXArray.zeros([outDim, inDim / 128], dtype: .float16),
            groupSize: 128, bits: 2, mode: .affine)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let xh = prismHadamardTransform(
            x, block: hadamardBlock, signs: signs, inverse: false, dtype: computeDtype)
        var result = quantizedMatmul(
            xh, weight, scales: scales, biases: biases, transpose: true,
            groupSize: groupSize, bits: bits, mode: mode)
        if let bias {
            result = result + bias
        }
        return result
    }
}

/// Drop-in replacement for the packed embedding: dequantizes the gathered
/// rows, then applies the inverse FWHT.
final class PrismHadamardQuantizedEmbedding: QuantizedEmbedding {
    let signs: MLXArray
    let hadamardBlock: Int
    let computeDtype: DType

    init(_ other: Embedding, block: Int, dtype: DType) {
        let count = other.weight.dim(0)
        let dims = other.weight.dim(1)
        precondition(dims % 128 == 0, "packed width must be a multiple of 128")
        self.hadamardBlock = block
        self.computeDtype = dtype
        self.signs = MLXArray.ones([dims])
        super.init(
            weight: MLXArray.zeros([count, dims / 16], dtype: .uint32),
            scales: MLXArray.zeros([count, dims / 128], dtype: .float16),
            biases: MLXArray.zeros([count, dims / 128], dtype: .float16),
            groupSize: 128, bits: 2, mode: .affine)
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let s = x.shape
        let indices = x.flattened()
        let gathered = dequantized(
            weight[indices], scales: scales[indices],
            biases: biases == nil ? nil : biases![indices],
            groupSize: groupSize, bits: bits, mode: mode)
        return prismHadamardTransform(
            gathered.reshaped(s + [-1]), block: hadamardBlock, signs: signs,
            inverse: true, dtype: computeDtype
        ).reshaped(s + [-1])
    }
}

// MARK: - Layer swap

/// Replaces every packed projection/embedding of a freshly built Qwen3.5
/// graph with its Hadamard-aware counterpart, driven by the pack's `modules`
/// list. Paths in the list are relative to the language model
/// (`model.layers.N.…`, `lm_head`); both the VLM (`Qwen35`) and LLM
/// (`Qwen35Model`) graphs nest it under `language_model`, so one mapping
/// serves both.
func prismSwapHadamardLayers(root: Module, meta: PrismHadamardPackMeta) throws -> Module {
    var wanted = [String: PrismHadamardModuleMeta]()
    wanted.reserveCapacity(meta.modules.count)
    for m in meta.modules {
        wanted["language_model." + m.path] = m
    }

    var updates = [(String, Module)]()
    updates.reserveCapacity(meta.modules.count)
    for (path, module) in root.leafModules().flattened() {
        guard let m = wanted[path] else { continue }
        guard !(module is Quantized) else { continue }
        let dtype: DType
        switch m.dtype {
        case "float16": dtype = .float16
        default:
            throw ModelFactoryError.invalidConfiguration(
                "prism_hadamard_qwen35: unsupported module dtype '\(m.dtype)' at \(path)")
        }
        if m.embedding {
            guard let embedding = module as? Embedding else {
                throw ModelFactoryError.invalidConfiguration(
                    "prism_hadamard_qwen35: expected Embedding at \(path)")
            }
            updates.append(
                (path, PrismHadamardQuantizedEmbedding(embedding, block: m.block, dtype: dtype)))
        } else {
            guard let linear = module as? Linear else {
                throw ModelFactoryError.invalidConfiguration(
                    "prism_hadamard_qwen35: expected Linear at \(path)")
            }
            updates.append(
                (path, PrismHadamardQuantizedLinear(linear, block: m.block, dtype: dtype)))
        }
    }

    guard updates.count == meta.modules.count else {
        let hit = Set(updates.map { $0.0 })
        let missing = meta.modules.map { "language_model." + $0.path }.filter { !hit.contains($0) }
        throw ModelFactoryError.invalidConfiguration(
            "prism_hadamard_qwen35: matched \(updates.count)/\(meta.modules.count) packed modules;"
                + " missing: \(missing.prefix(8).joined(separator: ", "))")
    }

    return try root.update(
        modules: .unflattened(updates), verify: .none, path: [], modulePath: [])
}

// MARK: - Registration (Nemotron-style, idempotent)

/// Registers `prism_hadamard_qwen35` in both the VLM and LLM type registries.
/// Safe to call on every load; skipped once registered.
func registerPrismHadamardQwen35ModelTypes() async {
    if !(await VLMTypeRegistry.shared.contains("prism_hadamard_qwen35")) {
        await VLMTypeRegistry.shared.registerModelType("prism_hadamard_qwen35") { data in
            let configuration = try JSONDecoder.json5().decode(
                MLXVLM.Qwen35Configuration.self, from: data)
            let meta = try JSONDecoder.json5().decode(PrismHadamardPackMeta.self, from: data)
            guard !meta.modules.isEmpty else {
                throw ModelFactoryError.invalidConfiguration(
                    "prism_hadamard_qwen35: config.json has no `modules` list")
            }
            let model = Qwen35(configuration)
            return try prismSwapHadamardLayers(root: model, meta: meta) as! Qwen35
        }
    }
    if !(await LLMTypeRegistry.shared.contains("prism_hadamard_qwen35")) {
        await LLMTypeRegistry.shared.registerModelType("prism_hadamard_qwen35") { data in
            let configuration = try JSONDecoder.json5().decode(
                MLXLLM.Qwen35Configuration.self, from: data)
            let meta = try JSONDecoder.json5().decode(PrismHadamardPackMeta.self, from: data)
            guard !meta.modules.isEmpty else {
                throw ModelFactoryError.invalidConfiguration(
                    "prism_hadamard_qwen35: config.json has no `modules` list")
            }
            let model = Qwen35Model(configuration)
            return try prismSwapHadamardLayers(root: model, meta: meta) as! Qwen35Model
        }
    }
}
