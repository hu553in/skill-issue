# Third-party dependencies

The app uses [JOSESwift](https://github.com/airsidemobile/JOSESwift), licensed under Apache 2.0, and
[speech-swift](https://github.com/soniqo/speech-swift), licensed under Apache 2.0. `Package.swift`
pins these dependencies; `Package.resolved` records the transitive dependency tree. No source
patches are applied. Dependency license texts remain in the upstream packages.

The model is
[Nemotron 3.5 ASR Streaming 0.6B CoreML INT8](https://huggingface.co/aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8)
at the revision pinned in [the model manifest](native/Resources/model.json), with the
[Open Model, Data, and Weights License 1.1](https://openmdw.ai/license/1-1/). Model weights are
downloaded from the upstream repository, not included in this source tree.
`native/Resources/model.json` pins every required file's size and SHA256.
