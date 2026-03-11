# Build Workflow Analysis

## Scope

This note validates the repo's current build and test shape, records the SwiftPM MLX failure mode that existed before the workflow hardening, and documents the workflow changes that were applied.

## Validated Repo Facts

- The repo is package-first. `Package.swift` is the source of truth and there is no checked-in Xcode project or workspace.
- SwiftPM remains the source of truth for the package graph, unit tests, and day-to-day development.
- SwiftPM MLX execution still depends on the repo-local `scripts/build_mlx_metallib.sh` workaround because the SwiftPM path does not emit the default MLX metallib on its own.
- Release packaging is now an explicit Xcode/xcodebuild path through `scripts/build.sh`, and the checked-in CI workflow uses that path for nightly CLI packaging.

## Measured Gap Before Changes

On March 10, 2026, a clean temporary worktree with no `.build` products showed that MLX-backed SwiftPM tests were not self-preparing:

```text
swift test --filter VisionIOTests/testImageTensorConverter_convertsAndNormalizes
...
Test skipped - mlx.metallib not found at .../.build/arm64-apple-macosx/debug/mlx.metallib. Run scripts/build_mlx_metallib.sh first.
```

That meant the default `swift test` workflow could report green while silently skipping MLX-backed deterministic coverage on a clean checkout.

## Decision

The right split for this repo remains:

- Keep SwiftPM as the source of truth for tests and day-to-day development.
- Keep Xcode/xcodebuild as the release-artifact builder.
- Hide the SwiftPM metallib workaround behind stable repo workflows instead of requiring contributors to remember manual preparation steps.
- Add a release-path smoke check without trying to move the full validation matrix into CI.

## Implemented Changes

- Hardened `Tests/VLMRuntimeKitTests`, `Tests/DocLayoutAdapterTests`, and `Tests/GLMOCRAdapterTests` so MLX-backed SwiftPM tests prepare and colocate `mlx.metallib` automatically.
- Added small `MLXTestCase` base helpers for the always-on deterministic MLX test classes so the default suite no longer repeats one-off setup code.
- Added `scripts/build.sh` as the Xcode release-build wrapper with the validated non-interactive plugin flags and environment overrides.
- Added `.github/workflows/ci.yml` to run `swift test` on pull requests and to build/package a nightly CLI artifact on pushes to `main`.
- Added a release smoke check that runs `GLMOCRCLI --help` from the release products after copying `default.metallib` next to the binary.
- Updated `README.md`, `AGENTS.md`, `docs/overview.md`, and `docs/golden_checks.md` so the documented workflows match the codebase.

## Validation After Changes

Commands run and outcomes:

- `swift test`
  - passed
  - `94` tests executed, `10` skipped, `0` failures
- Clean-worktree check:
  - first run on a plain filesystem copy of the modified tree with no `.build`
  - `swift test --filter VisionIOTests/testImageTensorConverter_convertsAndNormalizes`
  - `swift test --skip-build --filter GLMOCRFusionVectorizedTests/testFuse_vectorizedMatchesNaiveReference_multiBatch`
  - `swift test --skip-build --filter PPDocLayoutV3MinSizePrefilterTests/testMaskLogitsForTinyBoxes_masksInvalidQueriesBeforeSelection`
  - all passed without a manual `scripts/build_mlx_metallib.sh` step
- `GLMOCR_TEST_RUN_FORWARD_PASS=1 swift test --filter GLMOCRForwardPassIntegrationTests/testForwardPass_smoke`
  - passed
- `DERIVED_DATA_PATH=./dist ./scripts/build.sh`
  - passed
- Release-directory smoke and package check
  - copied `default.metallib` next to `GLMOCRCLI`
  - `./GLMOCRCLI --help` succeeded
  - packaged zip contained exactly `GLMOCRCLI` and `default.metallib`

## Remaining Tradeoffs

- SwiftPM MLX execution still depends on the repo-local metallib generation script. That is acceptable for dev/test support, but it is still less elegant than the Xcode bundle path used for release artifacts.
- The checked-in CI workflow intentionally keeps model-backed parity and golden lanes opt-in because they depend on cached snapshots and are much more expensive than the default verification path.
- The release smoke check validates packaging and process startup, not full inference. That is intentional because full runtime coverage already lives in the opt-in integration and examples lanes.
