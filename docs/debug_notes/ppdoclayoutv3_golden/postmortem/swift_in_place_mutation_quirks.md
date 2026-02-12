## Recap of the fix

The core fix was made in `PPDocLayoutV3MultiscaleDeformableAttentionCore.forward(...)` in `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Decoder.swift`:

```swift
-            hiddenStates += positionEmbeddings
+            hiddenStates = hiddenStates + positionEmbeddings
```

### debug context (docs + code)

### What was failing

The failing signal was **PP-DocLayout-V3 forward-pass golden drift** in the Swift port (target `DocLayoutAdapter`), across:

* CPU/float32 golden (`PPDocLayoutV3GoldenFloat32IntegrationTests`)
* MPS/float16 golden (`PPDocLayoutV3GoldenIntegrationTests`)

To make the failure localizable, you added **intermediate parity fixtures**:

* **v3**: “pre-decoder” intermediates (`ppdoclayoutv3_forward_golden_cpu_float32_v3.json`)
* **v4**: **decoder layer-0** internals (`ppdoclayoutv3_forward_golden_cpu_float32_v4.json`)

(These are laid out in `docs/debug_notes/ppdoclayoutv3_golden/debugging_ppdoclayoutv3_golden.md`, and the original step-by-step plan is archived at `docs/debug_notes/ppdoclayoutv3_golden/archive/2026-02-12/debug_plan.md`.)

### **Swift implementation: `MLXArray` aliasing + compound assignment in decoder cross-attn (real divergence)**

* The actual golden drift root cause was in `Sources/ModelAdapters/DocLayout/PPDocLayoutV3Decoder.swift`, inside:

  * `PPDocLayoutV3MultiscaleDeformableAttentionCore.forward(...)`

Old (buggy) behavior:

```swift
var hiddenStates = hiddenStates
hiddenStates += positionEmbeddings
```

Because `MLXArray` behaves like a **reference-semantic handle**, the `+=` mutated underlying storage shared with the caller’s tensor. In the decoder layer, that caller-owned tensor is also used as the **residual** (`residual = hiddenStates`), so the residual path became “silently modified,” and the drift then blew up downstream.

Fix (current):

```swift
hiddenStates = hiddenStates + positionEmbeddings
```

You also added a regression test:

* `Tests/DocLayoutAdapterTests/PPDocLayoutV3DecoderMutationTests.swift`
  which asserts the attention block does **not** mutate the input `hiddenStates`.

Net result: CPU/float32 golden + MPS/float16 golden + v3/v4 parity all pass again.

Follow-ups (landed):

- Disabled SwiftLint’s `shorthand_operator` rule in `.swiftlint.yml` so the linter no longer pushes `x = x + y` into `x += y` in MLX code paths.
- Removed remaining compound assignments on `MLXArray` across the repo as a defensive rule-of-thumb.


## The introduction of the bug

The trigger of the issue was that, the Swiftlint reports error upon the fix line,
```swift
            hiddenStates = hiddenStates + positionEmbeddings
```

The message was,
```text
Sources/ModelAdapters/DocLayout/PPDocLayoutV3Decoder.swift:202:13: error: Shorthand Operator Violation: Prefer shorthand operators (+=, -=, *=, /=) over doing the operation and assigning (shorthand_operator)
```

You recall This was why you edited the line to "+=" and introduced the bug.

## `+=` vs `= x + y`: syntax + semantics

### Swift language level
- `hiddenStates += positionEmbeddings` calls the `+=` operator: `static func += (lhs: inout T, rhs: T)` (or similar). The LHS is passed as `inout`, so the operator is *allowed* to mutate the existing storage behind `lhs` “in place”.
- `hiddenStates = hiddenStates + positionEmbeddings` calls the `+` operator to produce a new value, then rebinds `hiddenStates` to that result.

For most *value-semantic* types (e.g., `Int`, `Float`, `Array` with CoW), these are *usually* equivalent in observable behavior (ignoring subtleties like evaluation count for complex lvalues).

### Why they differ for `MLXArray`
`MLXArray` behaves like a reference-semantic handle to underlying tensor storage/graph. Copies like `var a = b` typically **alias** the same underlying object/storage.

So:
- `+=` can mutate the underlying tensor **in place**, affecting *all aliases*.
- `x = x + y` rebinds `x` to a **new** tensor result, leaving other aliases pointing at the old one.

That’s exactly what bit you here:

```swift
func f(hiddenStates: MLXArray, positionEmbeddings: MLXArray) {
    var hiddenStates = hiddenStates   // aliases the input handle
    hiddenStates += positionEmbeddings // mutates the aliased underlying tensor
    // caller’s tensor is now “changed” too
}
```

Even if the caller’s binding is `let`, that only prevents *rebinding the handle*, not mutating the object the handle points to.

## Why SwiftLint reported the violation

SwiftLint’s `shorthand_operator` rule is a **pure syntax** rule: it matches patterns like `x = x + y` / `x = x * y` and recommends `x += y` / `x *= y`.

It is not type-aware, so it assumes the transformation is semantics-preserving. That’s generally true for standard numeric/value types, but **not** for reference-semantic tensor handles where `+=` is implemented as an in-place update.

If your tooling runs SwiftLint in “strict” mode (or treats warnings as errors), this style suggestion becomes a failing “error”, pressuring the exact change that reintroduced the bug.

## Long-term options for the SwiftLint issue

You already did the safest short-term thing (`// swiftlint:disable:next shorthand_operator`). Better long-term options:

1) **Disable `shorthand_operator` for MLX-heavy code paths**
- Best when tensor code frequently needs out-of-place ops for alias safety.
- Implement via config instead of inline comments:
  - Prefer `per_file_ignores` for just the affected files (or a glob for `Sources/ModelAdapters/**` if you want it broader).
  - Or disable the rule globally if this repo regularly manipulates reference-semantic tensor handles.

This repo now uses the “disable via config” option to avoid accidental reintroduction during lint-only refactors.

2) **Keep the rule, but avoid the trigger pattern**
- Rewrite to a functional form SwiftLint won’t rewrite:
  - `hiddenStates = add(hiddenStates, positionEmbeddings)` (if you have/choose such an API)
  - `hiddenStates = hiddenStates.adding(positionEmbeddings)` (a tiny extension wrapper)
- This keeps SwiftLint happy without lying about semantics, but it does make code more verbose.

3) **Keep your current inline disable, but make it self-defending**
- Add a short rationale right above it so future refactors don’t “clean it up” back into `+=`.

## Preventing reintroduction of similar subtle issues (project-wide)

Layer defenses; don’t rely on one thing:

1) **Coding guideline (document + enforce in reviews)**
- Treat `MLXArray` as *reference-semantic*.
- Default rule: *no compound assignment (`+=`, `*=`, …) on tensors* unless you have proven non-aliasing (freshly created, not shared across residual paths, etc.).

2) **Targeted regression tests for mutation hazards**
- Add/keep tests like the one you now have (`PPDocLayoutV3DecoderMutationTests`) that assert critical kernels do not mutate inputs. These catch the class of bug even if lint/formatting pushes code around.

3) **Adjust linting to align with tensor semantics**
- The important thing is: your lint rules must not encourage unsafe rewrites in MLX code.
- Either disable `shorthand_operator` where tensors are manipulated, or replace it with a rule (even a coarse one) that discourages in-place ops in those directories.
