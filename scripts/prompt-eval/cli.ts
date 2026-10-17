/* oxlint-disable no-await-in-loop -- Generation and judging share one authenticated worker; billable calls are deliberately serial. */
import { appendFile } from "node:fs/promises";
import path from "node:path";

import type {
  Answer,
  AnswerSettings,
  FrozenCase,
  InputMessage,
} from "./evaluation";
import {
  command,
  defaultAnswerSettings,
  freezeCases,
  freezePrompt,
  judgeInput,
  judgePrompt,
  options,
  parseGrade,
  parseReady,
  parseResult,
  reserveOutput,
  rotate,
  sha256,
  validateSettings,
} from "./evaluation";

const root = path.resolve(import.meta.dir, "..", "..");
const help = `Usage: bun eval:prompts [options]

Compare HEAD with the working prompt using the ChatGPT account saved in Skill Issue.
Each case runs every variant; a blinded model judge compares the answers by default.
Calls consume that account's usage. No microphone, screen capture or app UI is started.

  --prompt LABEL=PATH             Repeat for each prompt variant
  --prompt LABEL=git:REF:PATH      Read a prompt from a Git commit or ref
  --case ID[,ID]                  Select cases (repeatable; default: all)
  --repeat N                      Runs per case and variant (default: 1)
  --model MODEL --effort EFFORT    Defaults to the saved app settings
  --judge-model MODEL             Defaults to the generator model
  --judge-effort EFFORT           Defaults to the generator effort
  --no-judge                      Generate answers without model grading
  --out DIRECTORY                New output directory (existing paths refused)
  --list                         List fixtures; no build, account access or calls
  --models                       List available models; no generation calls

Outputs: manifest.json, results.jsonl, report.md. Inputs and settings are frozen.
Answer settings come only from synthetic cases, never the app's personal fields.
Model outputs and model judgments remain nondeterministic and need human review.
Failures stop the run without automatic retries; completed results are preserved.
`;

interface Request {
  prompt: string;
  input: InputMessage[];
  language: string;
  model: string;
  effort: string;
  settings: AnswerSettings;
}

async function* jsonLines(stream: ReadableStream<Uint8Array>) {
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    let newline = buffer.indexOf("\n");
    while (newline !== -1) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (line !== "") {
        yield JSON.parse(line) as unknown;
      }
      newline = buffer.indexOf("\n");
    }
  }
  buffer += decoder.decode();
  if (buffer.trim() !== "") {
    yield JSON.parse(buffer) as unknown;
  }
}

async function startWorker() {
  if (process.platform !== "darwin") {
    throw new Error(
      "Prompt evals require macOS and the ChatGPT account saved in Skill Issue."
    );
  }
  const buildArgs = ["bun", "run", "build:prompt-eval"];
  process.stderr.write("Building the headless ChatGPT worker...\n");
  await command(root, buildArgs);
  const binOutput = await command(root, [...buildArgs, "--show-bin-path"]);
  const bin = binOutput.trim();
  const child = Bun.spawn([path.join(bin, "SkillIssue")], {
    cwd: root,
    stderr: "inherit",
    stdin: "pipe",
    stdout: "pipe",
  });
  const lines = jsonLines(child.stdout);
  async function read() {
    const result = await lines.next();
    if (result.done === true) {
      throw new Error(
        `ChatGPT worker exited before replying (exit ${await child.exited}).`
      );
    }
    return result.value;
  }
  let ending: Promise<unknown> | undefined;
  async function endInput() {
    ending ??= Promise.resolve(child.stdin.end());
    return await ending;
  }
  const interrupt = () => {
    // EOF also releases the native worker's blocking readLine while it is idle.
    // oxlint-disable-next-line promise/prefer-await-to-then -- Signal callbacks cannot wait for stdin before delivering SIGTERM.
    void endInput().catch(() => {
      // A worker that has already exited may have closed stdin first.
    });
    child.kill("SIGTERM");
  };
  process.on("SIGINT", interrupt);
  process.on("SIGTERM", interrupt);
  async function close() {
    try {
      await endInput();
    } catch (error) {
      // An interrupted write may already have closed the pipe; keep its original request error.
      if (
        !(error instanceof Error && "code" in error && error.code === "EPIPE")
      ) {
        throw error;
      }
    } finally {
      await child.exited;
      process.off("SIGINT", interrupt);
      process.off("SIGTERM", interrupt);
    }
  }
  try {
    const initial = await read();
    // Startup authentication failures use the same safe error envelope as requests.
    if (
      typeof initial === "object" &&
      initial !== null &&
      "ok" in initial &&
      initial.ok === false
    ) {
      parseResult(initial);
    }
    return {
      close,
      ready: parseReady(initial),
      request: async (request: Request) => {
        await child.stdin.write(`${JSON.stringify(request)}\n`);
        await child.stdin.flush();
        return parseResult(await read());
      },
    };
  } catch (error) {
    await close();
    throw error;
  }
}

type Record =
  | { type: "answer"; caseID: string; repeat: number; answer: Answer }
  | {
      type: "judge";
      caseID: string;
      repeat: number;
      candidateOrder: string[];
      response: ReturnType<typeof parseResult>;
      grade: ReturnType<typeof parseGrade>;
    }
  | {
      type: "judge-error";
      caseID: string;
      repeat: number;
      candidateOrder: string[];
      response: ReturnType<typeof parseResult>;
      error: string;
    }
  | { type: "status"; status: "completed" | "failed"; error?: string };

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function report(records: Record[], cases: FrozenCase[], status: string) {
  const lines = [
    "# Prompt comparison",
    "",
    `Status: ${status}. Exact inputs, prompt hashes and settings are in manifest.json.`,
    "",
    "Model grades are heuristic, not human verification or proof of correctness. All numerical ratings are 1-5; higher readability/opening is better, lower excess text is better. No code was executed by the judge. Repeated runs can disagree.",
    "",
  ];
  const comparisons = records.filter((record) => record.type === "judge");
  const answers = records.filter((record) => record.type === "answer");
  lines.push(
    `Completed answers: ${answers.length}. Valid model comparisons: ${comparisons.length}.`,
    ""
  );
  if (comparisons.length > 0) {
    const preferences = new Map<string, number>();
    for (const comparison of comparisons) {
      const { winner } = comparison.grade;
      preferences.set(winner, (preferences.get(winner) ?? 0) + 1);
    }
    lines.push(
      `Model preferences: ${[...preferences].map(([label, count]) => `${label}: ${count}`).join("; ")}.`,
      ""
    );
  }
  for (const record of records) {
    if (record.type === "status") {
      if (record.error !== undefined) {
        lines.push(`Run stopped: ${record.error}`, "");
      }
      continue;
    }
    const title =
      cases.find((item) => item.id === record.caseID)?.title ?? record.caseID;
    if (record.type === "answer") {
      const { answer } = record;
      lines.push(
        `## ${record.caseID}: ${title} / run ${record.repeat} / ${answer.variant}`,
        "",
        `Total: ${(answer.durationMs / 1000).toFixed(2)} s. First text: ${answer.firstTokenMs === null ? "unavailable" : `${(answer.firstTokenMs / 1000).toFixed(2)} s`}. Input/output tokens: ${answer.usage?.inputTokens ?? "unavailable"}/${answer.usage?.outputTokens ?? "unavailable"}.`,
        "",
        ...answer.text.split("\n").map((line) => `> ${line}`),
        ""
      );
    } else if (record.type === "judge") {
      lines.push(
        `### Model comparison: ${record.caseID} / run ${record.repeat}`,
        "",
        `Model preference: **${record.grade.winner}**.`,
        ""
      );
      for (const answer of record.grade.answers) {
        lines.push(
          `**${answer.variant}** - readability ${answer.readability}, opening ${answer.usefulOpening}, excess text ${answer.excessText}.`,
          "",
          answer.rationale,
          "",
          ...answer.criteria.map(
            (criterion) =>
              `- [${criterion.pass ? "x" : " "}] ${criterion.criterion}`
          ),
          ""
        );
      }
    } else {
      lines.push(
        `### Invalid model comparison: ${record.caseID} / run ${record.repeat}`,
        "",
        record.error,
        "",
        "The raw judge response is preserved in results.jsonl; no grade was accepted.",
        ""
      );
    }
  }
  return `${lines.join("\n")}\n`;
}

async function main() {
  const config = options(Bun.argv.slice(2));
  if (config.help === true) {
    process.stdout.write(help);
    return;
  }
  if (config.models === true) {
    const worker = await startWorker();
    try {
      process.stdout.write(`${JSON.stringify(worker.ready, null, 2)}\n`);
    } finally {
      await worker.close();
    }
    return;
  }
  const cases = await freezeCases(root, config.caseIDs);
  if (config.list === true) {
    process.stdout.write(
      `${cases.map((item) => `${item.id}\t${item.language}\t${item.title}`).join("\n")}\n`
    );
    return;
  }
  const prompts = await Promise.all(
    config.prompts.map(async (source) => await freezePrompt(root, source))
  );
  const gitOutput = await command(root, ["git", "rev-parse", "HEAD"]);
  const gitSHA = gitOutput.trim();
  const output = path.resolve(
    root,
    config.out ??
      `.build/prompt-evals/${new Date().toISOString().replaceAll(":", "-")}`
  );
  await reserveOutput(output);
  const worker = await startWorker();
  try {
    const model = config.model ?? worker.ready.model;
    const effort = config.effort ?? worker.ready.effort;
    const judgeModel = config["judge-model"] ?? model;
    const judgeEffort = config["judge-effort"] ?? effort;
    const generatorCapabilities = validateSettings(worker.ready, model, effort);
    const judgeCapabilities =
      config["no-judge"] === true
        ? null
        : validateSettings(worker.ready, judgeModel, judgeEffort);
    const comparisons = cases.length * config.repeat;
    const count =
      comparisons * (prompts.length + (config["no-judge"] === true ? 0 : 1));
    await Bun.write(
      path.join(output, "manifest.json"),
      `${JSON.stringify(
        {
          cases,
          createdAt: new Date().toISOString(),
          generator: {
            effort,
            model,
            supportsVerbosity: generatorCapabilities.supportsVerbosity,
          },
          gitSHA,
          judge:
            judgeCapabilities === null
              ? null
              : {
                  effort: judgeEffort,
                  model: judgeModel,
                  prompt: judgePrompt,
                  settings: defaultAnswerSettings(),
                  sha256: sha256(judgePrompt),
                  supportsVerbosity: judgeCapabilities.supportsVerbosity,
                },
          order:
            "rotate variants by case index + repeat index; rotate judge candidates by one more position",
          plannedCalls: count,
          prompts,
          repeat: config.repeat,
          version: 2,
        },
        null,
        2
      )}\n`
    );
    process.stderr.write(
      `${cases.length} cases, ${prompts.length} variants, ${config.repeat} repeats: ${count} generation/judge calls on ${model} (${effort}).\nResults: ${output}\n`
    );
    const records: Record[] = [];
    const save = async (record: Record) => {
      await appendFile(
        path.join(output, "results.jsonl"),
        `${JSON.stringify(record)}\n`,
        { mode: 0o600 }
      );
      records.push(record);
      await Bun.write(
        path.join(output, "report.md"),
        report(
          records,
          cases,
          record.type === "status" ? record.status : "running"
        )
      );
    };
    let pending = "starting evaluation";
    try {
      for (const [caseIndex, item] of cases.entries()) {
        for (let repeat = 1; repeat <= config.repeat; repeat += 1) {
          const answers: Answer[] = [];
          for (const prompt of rotate(prompts, caseIndex + repeat - 1)) {
            pending = `${item.id}, run ${repeat}, variant ${prompt.label}`;
            process.stderr.write(
              `[${item.id} ${repeat}/${config.repeat}] ${prompt.label}\n`
            );
            const response = await worker.request({
              effort,
              input: item.input,
              language: item.language,
              model,
              prompt: prompt.text,
              settings: item.settings,
            });
            const answer = { ...response, variant: prompt.label };
            await save({ answer, caseID: item.id, repeat, type: "answer" });
            answers.push(answer);
          }
          if (config["no-judge"] !== true) {
            pending = `${item.id}, run ${repeat}, blinded comparison`;
            // Blinding only sends candidate IDs and answer text, never variant labels or prompts.
            const candidates = rotate(answers, 1);
            const candidateOrder = candidates.map((answer) => answer.variant);
            process.stderr.write(
              `[${item.id} ${repeat}/${config.repeat}] blinded comparison\n`
            );
            const response = await worker.request({
              effort: judgeEffort,
              input: judgeInput(item, candidates),
              language: "English",
              model: judgeModel,
              prompt: judgePrompt,
              settings: defaultAnswerSettings(),
            });
            let grade: ReturnType<typeof parseGrade>;
            try {
              grade = parseGrade(response.text, item, candidates);
            } catch (error) {
              await save({
                candidateOrder,
                caseID: item.id,
                error: errorText(error),
                repeat,
                response,
                type: "judge-error",
              });
              throw error;
            }
            await save({
              candidateOrder,
              caseID: item.id,
              grade,
              repeat,
              response,
              type: "judge",
            });
          }
        }
      }
      await save({ status: "completed", type: "status" });
    } catch (error) {
      const failure = new Error(`${pending}: ${errorText(error)}`, {
        cause: error,
      });
      await save({ error: failure.message, status: "failed", type: "status" });
      throw failure;
    }
  } finally {
    await worker.close();
  }
}

try {
  await main();
} catch (error) {
  process.stderr.write(`Prompt eval stopped: ${errorText(error)}\n`);
  process.exitCode = 1;
}
