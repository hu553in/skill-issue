# Third-party dependencies

The native app uses [JOSESwift](https://github.com/airsidemobile/JOSESwift),
[swift-openapi-runtime](https://github.com/apple/swift-openapi-runtime) and
[speech-swift](https://github.com/soniqo/speech-swift), all licensed under Apache 2.0.
`Package.swift` pins these dependencies; `Package.resolved` records the transitive dependency tree.
No source patches are applied. Web runtime dependencies are declared in `package.json` and resolved
in `bun.lock`.

Builds include dependency license and notice texts with an `index.json` listing resolved versions
and file paths:

- Mac app: `Skill Issue.app/Contents/Resources/Notices/`.
- Web viewer: `/notices/`, with the index at `/notices/index.json`.

Both include this repository's `LICENSE` and `THIRD_PARTY.md`.

The model is
[Nemotron 3.5 ASR Streaming 0.6B CoreML INT8](https://huggingface.co/aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8)
at the revision pinned in [the model manifest](native/Resources/model.json), with the
[Open Model, Data, and Weights License 1.1](https://openmdw.ai/license/1-1/). Model weights are
downloaded from the upstream repository, not included in this source tree.
`native/Resources/model.json` pins every required file's size and SHA256.
