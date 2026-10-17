#if PROMPT_EVAL
    import AppKit
    import Darwin

    // Built only by eval:prompts. No application delegate, capture, or UI is created.
    @MainActor enum PromptEvaluation {
        private static var servingTask: Task<Void, Never>?

        static func run() {
            servingTask = Task {
                do {
                    try await serve()
                    guard !Task.isCancelled else { return }
                    exit(0)
                } catch {
                    guard !Task.isCancelled else { return }
                    emit(["ok": false, "error": message(error)])
                    exit(1)
                }
            }
            dispatchMain()
        }

        private static func serve() async throws {
            let bundleID = "com.github.hu553in.skill-issue"
            let lockDirectory = URL.cachesDirectory.appending(path: bundleID)
            try FileManager.default.createDirectory(
                at: lockDirectory, withIntermediateDirectories: true)
            let lock = Darwin.open(
                lockDirectory.appending(path: "prompt-eval.lock").path,
                O_CREAT | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard lock >= 0 else { throw AppFailure.failed }
            defer { Darwin.close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                emit(["ok": false, "error": "Another prompt evaluation is already running."])
                exit(1)
            }
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            else {
                emit([
                    "ok": false,
                    "error":
                        "Quit Skill Issue before evaluating so only one process refreshes the saved account.",
                ])
                exit(1)
            }
            let defaults = UserDefaults(suiteName: bundleID)!
            let chatGPT = ChatGPT(defaults: defaults, openAuthorization: { _ in false })
            // Cancel new requests, but let an in-flight refresh persist its rotated token before exit.
            let signals = [SIGINT, SIGTERM].map { number in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    Task { @MainActor in
                        servingTask?.cancel()
                        await chatGPT.finishPendingRefresh()
                        exit(130)
                    }
                }
                source.resume()
                return source
            }
            defer {
                for source in signals { source.cancel() }
            }
            try await chatGPT.restore()
            try Task.checkCancellation()
            guard chatGPT.isSignedIn else { throw ChatGPTFailure.signInRequired }
            guard chatGPT.canUsePlan else { throw ChatGPTFailure.planDisabled }
            let models = try await chatGPT.listModels()
            let savedModel = defaults.string(forKey: "chatGPTModel")
            let selected =
                models.first { $0.slug == savedModel }
                ?? models.first { $0.slug == "gpt-6-luna" } ?? models[0]
            let savedEffort = defaults.string(forKey: "chatGPTReasoningEffort") ?? ""
            emit([
                "type": "ready", "model": selected.slug,
                "effort": selected.slug == savedModel && selected.supportsEffort(savedEffort)
                    ? savedEffort : selected.defaultEffort,
                "models": models.map { ["slug": $0.slug, "efforts": $0.efforts] as [String: Any] },
            ])
            while let line = readLine() {
                try Task.checkCancellation()
                let result = try await evaluate(line, chatGPT: chatGPT, models: models)
                emit(result)
            }
        }

        private static func evaluate(
            _ line: String, chatGPT: ChatGPT, models: [ChatGPTModel]
        ) async throws -> [String: Any] {
            guard
                let request = try JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                let prompt = request["prompt"] as? String, !prompt.isEmpty,
                let input = request["input"] as? [[String: Any]], !input.isEmpty,
                let language = request["language"] as? String, !language.isEmpty,
                let slug = request["model"] as? String,
                let model = models.first(where: { $0.slug == slug }),
                let effort = request["effort"] as? String, model.supportsEffort(effort)
            else { throw AppFailure.failed }
            let start = ContinuousClock.now
            var firstTokenMs: Double?
            var text = ""
            let usage = try await chatGPT.answer(
                input: input, language: language, model: model, effort: effort, prompt: prompt
            ) { chunk in
                if !chunk.isEmpty && firstTokenMs == nil {
                    firstTokenMs = milliseconds(since: start)
                }
                text += chunk
            }
            return [
                "ok": true, "text": text, "durationMs": milliseconds(since: start),
                "firstTokenMs": firstTokenMs as Any? ?? NSNull(),
                "usage": usage as Any? ?? NSNull(),
            ]
        }

        private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now).components
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }

        private static func message(_ error: Error) -> String {
            guard let failure = error as? ChatGPTFailure else {
                return "Prompt evaluation failed. Check the request and connection, then retry."
            }
            // Server response bodies and account identifiers never enter evaluation artifacts.
            return failure.message + (failure.status.map { " (HTTP \($0))" } ?? "")
        }

        private static func emit(_ value: [String: Any]) {
            guard
                var data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            else { exit(1) }
            data.append(10)
            FileHandle.standardOutput.write(data)
        }
    }
#endif
