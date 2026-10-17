import { expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import type {
  Answer,
  EvalCase,
  FrozenCase,
} from "../scripts/prompt-eval/evaluation";
import {
  buildInput,
  freezeCases,
  freezePrompt,
  judgeInput,
  options,
  parseCases,
  parseGrade,
  parsePrompt,
  parseReady,
  parseResult,
  reserveOutput,
  rotate,
  sha256,
  validateSettings,
} from "../scripts/prompt-eval/evaluation";

function fixture(): EvalCase {
  return {
    criteria: ["Preserve the input array.", "Answer the memory follow-up."],
    id: "memory-follow-up",
    language: "English",
    observations: [
      {
        answer: "Sort the array in place.",
        completed: false,
        cutoff: 10,
        screenshot: "code.png",
        transcript: [
          {
            end: 8,
            id: "first",
            source: "computer",
            start: 2,
            text: "Find duplicates without modifying the input.",
          },
        ],
      },
      {
        cutoff: 20,
        transcript: [
          {
            end: 19,
            id: "next",
            source: "computer",
            start: 18,
            text: "What about memory?",
          },
        ],
      },
    ],
    title: "Memory after an incomplete suggestion",
  };
}

function frozen(): FrozenCase {
  const [item] = parseCases([fixture()]);
  if (!item) {
    throw new Error("Missing case.");
  }
  return {
    ...item,
    input: buildInput(
      item,
      new Map([["code.png", "data:image/png;base64,AA=="]])
    ),
    sha256: "fixture",
  };
}

const answers: Answer[] = [
  {
    durationMs: 1000,
    firstTokenMs: 100,
    ok: true,
    text: "Use O(n) extra space for a set.",
    usage: null,
    variant: "new",
  },
  {
    durationMs: 1200,
    firstTokenMs: 80,
    ok: true,
    text: "Sort it in place.",
    usage: null,
    variant: "head",
  },
];

function grade() {
  return {
    answers: [
      {
        criteria: [
          { id: "R1", pass: true },
          { id: "R2", pass: true },
        ],
        excessText: 1,
        label: "C1",
        rationale: "Uses a set without mutation.",
        readability: 5,
        usefulOpening: 5,
      },
      {
        criteria: [
          { id: "R1", pass: false },
          { id: "R2", pass: false },
        ],
        excessText: 1,
        label: "C2",
        rationale: "Mutates input and omits memory.",
        readability: 4,
        usefulOpening: 2,
      },
    ],
    winner: "C1",
  };
}

test("eval observations match native history fields and preserve incomplete suggestions", () => {
  const { input } = frozen();
  expect(input).toHaveLength(3);
  const [first] = input;
  if (!first || first.role !== "user") {
    throw new Error("Expected observation.");
  }
  expect(first.content).toEqual([
    {
      text: JSON.stringify({
        cutoff_seconds: 10,
        request_id: "eval-memory-follow-up-1",
        screenshot: {
          captured_at_seconds: 10,
          description: "Main Mac display at this request",
        },
        transcript: [
          {
            end_seconds: 8,
            id: "first",
            source: "computer",
            start_seconds: 2,
            text: "Find duplicates without modifying the input.",
          },
        ],
      }),
      type: "input_text",
    },
    { image_url: "data:image/png;base64,AA==", type: "input_image" },
  ]);
  expect(input[1]).toEqual({
    content:
      "[Incomplete suggestion: generation was cancelled or failed.]\nSort the array in place.",
    role: "assistant",
  });
  expect(input[2]?.role).toBe("user");

  const completed = fixture();
  completed.observations = completed.observations.map((turn, index) =>
    index === 0 ? { ...turn, completed: true } : turn
  );
  const [parsed] = parseCases([completed]);
  if (parsed === undefined) {
    throw new Error("Missing case.");
  }
  expect(
    buildInput(parsed, new Map([["code.png", "data:image/png;base64,AA=="]]))[1]
  ).toEqual({ content: "Sort the array in place.", role: "assistant" });
  const capturedLater = structuredClone(parsed);
  const [firstTurn] = capturedLater.observations;
  if (!firstTurn) {
    throw new Error("Missing observation.");
  }
  firstTurn.screenshotTime = 12;
  const [later] = parseCases([capturedLater]);
  if (!later) {
    throw new Error("Missing case.");
  }
  const [message] = buildInput(
    later,
    new Map([["code.png", "data:image/png;base64,AA=="]])
  );
  if (message?.role !== "user" || message.content[0]?.type !== "input_text") {
    throw new Error("Missing observation content.");
  }
  expect(JSON.parse(message.content[0].text)).toMatchObject({
    cutoff_seconds: 10,
    screenshot: { captured_at_seconds: 12 },
  });
  expect(() => buildInput(parsed, new Map())).toThrow("missing frozen image");
});

test("fixture validation rejects leaked target answers, duplicated criteria and impossible times", () => {
  const target = fixture();
  target.observations = target.observations.map((turn, index) =>
    index === 1 ? { ...turn, answer: "A leaked expected answer." } : turn
  );
  expect(() => parseCases([target])).toThrow("final observation");
  const times = fixture();
  times.observations = times.observations.map((turn, index) =>
    index === 1
      ? {
          ...turn,
          transcript: turn.transcript.map((part) => ({ ...part, end: 30 })),
        }
      : turn
  );
  expect(() => parseCases([times])).toThrow("transcript times");
  const chronological = fixture();
  chronological.observations = chronological.observations.map((turn, index) =>
    index === 1 ? { ...turn, cutoff: 1 } : turn
  );
  expect(() => parseCases([chronological])).toThrow("chronological");
  expect(() => parseCases([fixture(), fixture()])).toThrow("Case IDs");
  expect(() =>
    parseCases([{ ...fixture(), criteria: ["Same", "Same"] }])
  ).toThrow("criteria must be unique");
  const noImage = fixture();
  noImage.observations = noImage.observations.map((turn, index) =>
    index === 1 ? { ...turn, screenshotTime: 20 } : turn
  );
  expect(() => parseCases([noImage])).toThrow("screenshotTime requires");
});

test("prompt parsing supports Git refs and equals in file names without shell interpretation", () => {
  expect(parsePrompt("old=git:HEAD~2:native/Resources/prompt.md")).toEqual({
    file: "native/Resources/prompt.md",
    label: "old",
    ref: "HEAD~2",
    source: "git:HEAD~2:native/Resources/prompt.md",
  });
  expect(parsePrompt("local=file:evals/prompt=x.md").file).toBe(
    "evals/prompt=x.md"
  );
  for (const value of [
    "bare.md",
    "../label=prompt.md",
    "x=",
    "x=file:",
    "x=git:HEAD",
    "tie=prompt.md",
  ]) {
    expect(() => parsePrompt(value)).toThrow();
  }
});

test("CLI options reject ambiguous or invalid requests before account access", () => {
  expect(
    options(["--case", "one,two", "--case", "three", "--repeat", "2"]).caseIDs
  ).toEqual(["one", "two", "three"]);
  expect(options(["--prompt", "only=prompt.md", "--no-judge"]).prompts).toEqual(
    ["only=prompt.md"]
  );
  for (const args of [
    ["--repeat", "0"],
    ["--repeat", "1.5"],
    ["--prompt", "a=x", "--prompt", "a=y"],
    ["--prompt", "a=x"],
    ["--case", "a,"],
    ["--no-judge", "--judge-model", "model"],
    ["--unknown"],
    ["--model", " "],
  ]) {
    expect(() => options(args)).toThrow();
  }
  expect(rotate(["head", "new", "other"], 4)).toEqual(["new", "other", "head"]);
});

test("blinded judge receives original observations and answers without variant metadata", () => {
  const item = frozen();
  const input = judgeInput(item, answers);
  expect(input.slice(0, -1)).toEqual(item.input);
  const last = input.at(-1);
  if (!last || last.role !== "user" || last.content[0]?.type !== "input_text") {
    throw new Error("Missing grading payload.");
  }
  expect(JSON.parse(last.content[0].text)).toEqual({
    candidates: [
      { label: "C1", text: "Use O(n) extra space for a set." },
      { label: "C2", text: "Sort it in place." },
    ],
    criteria: [
      { id: "R1", text: "Preserve the input array." },
      { id: "R2", text: "Answer the memory follow-up." },
    ],
    requiredAnswerLanguage: "English",
  });
});

test("grade validation binds ordered criterion IDs and restores readable criteria and variant labels", () => {
  const valid = grade();
  valid.answers.reverse();
  const result = parseGrade(JSON.stringify(valid), frozen(), answers);
  expect(result.winner).toBe("new");
  expect(result.answers[0]?.variant).toBe("head");
  expect(result.answers[0]?.criteria).toEqual([
    { criterion: "Preserve the input array.", pass: false },
    { criterion: "Answer the memory follow-up.", pass: false },
  ]);
  const invalid = [
    { ...grade(), winner: "new" },
    { ...grade(), answers: [grade().answers[0], grade().answers[0]] },
    { ...grade(), answers: [grade().answers[0]] },
    {
      ...grade(),
      answers: [{ ...grade().answers[0], label: "C9" }, grade().answers[1]],
    },
    ...[
      ["R1", "R9"],
      ["R1", "R1"],
      ["R2", "R1"],
      ["R1"],
      ["R1", "R2", "R3"],
    ].map((ids) => ({
      ...grade(),
      answers: [
        {
          ...grade().answers[0],
          criteria: ids.map((id) => ({ id, pass: true })),
        },
        grade().answers[1],
      ],
    })),
    {
      ...grade(),
      answers: [{ ...grade().answers[0], readability: 6 }, grade().answers[1]],
    },
    {
      ...grade(),
      answers: [
        {
          ...grade().answers[0],
          criteria: [
            { id: "R1", pass: "true" },
            { id: "R2", pass: true },
          ],
        },
        grade().answers[1],
      ],
    },
  ];
  for (const value of invalid) {
    expect(() =>
      parseGrade(JSON.stringify(value), frozen(), answers)
    ).toThrow();
  }
  expect(() => parseGrade("not JSON", frozen(), answers)).toThrow();
});

test("three-way grades preserve every variant when the judge changes order or returns a tie", () => {
  const candidates: Answer[] = [
    ...answers,
    {
      durationMs: 900,
      firstTokenMs: 90,
      ok: true,
      text: "A set uses O(n) memory and leaves the array unchanged.",
      usage: null,
      variant: "third",
    },
  ];
  const payload = {
    answers: [
      { ...grade().answers[0], label: "C3" },
      grade().answers[1],
      grade().answers[0],
    ],
    winner: "C3",
  };
  const result = parseGrade(JSON.stringify(payload), frozen(), candidates);
  expect(result.winner).toBe("third");
  expect(result.answers.map((answer) => answer.variant)).toEqual([
    "third",
    "head",
    "new",
  ]);
  expect(result.answers[0]?.criteria).toEqual([
    { criterion: "Preserve the input array.", pass: true },
    { criterion: "Answer the memory follow-up.", pass: true },
  ]);
  expect(
    parseGrade(
      JSON.stringify({ ...payload, winner: "tie" }),
      frozen(),
      candidates
    ).winner
  ).toBe("tie");
});

test("worker replies and selected settings fail closed on unsupported or invalid values", () => {
  const ready = parseReady({
    effort: "high",
    model: "model-one",
    models: [{ efforts: ["high", "medium"], slug: "model-one" }],
    type: "ready",
  });
  expect(() => {
    validateSettings(ready, "model-one", "medium");
  }).not.toThrow();
  expect(() => {
    validateSettings(ready, "unknown", "high");
  }).toThrow("not available");
  expect(() => {
    validateSettings(ready, "model-one", "max");
  }).toThrow("does not advertise");
  const plain = parseReady({
    effort: "",
    model: "plain",
    models: [{ efforts: [], slug: "plain" }],
    type: "ready",
  });
  expect(() => {
    validateSettings(plain, "plain", "");
  }).not.toThrow();
  expect(() => {
    validateSettings(plain, "plain", "high");
  }).toThrow("does not advertise");
  expect(options(["--effort", ""]).effort).toBe("");
  expect(() => parseResult({ error: "Account expired", ok: false })).toThrow(
    "Account expired"
  );
  expect(() =>
    parseResult({
      durationMs: 1,
      firstTokenMs: null,
      ok: true,
      text: "",
      usage: null,
    })
  ).toThrow();
  expect(
    parseResult({
      durationMs: 1,
      firstTokenMs: null,
      ok: true,
      text: "Answer",
      usage: { inputTokens: 9 },
    }).usage?.inputTokens
  ).toBe(9);
});

test("frozen prompt bytes are unchanged and existing output directories cannot be overwritten", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "skill-issue-eval-"));
  try {
    await Bun.write(path.join(root, "prompt.md"), "abc\n\n");
    const prompt = await freezePrompt(root, "test=prompt.md");
    await Bun.write(path.join(root, "prompt.md"), "changed");
    expect(prompt.text).toBe("abc\n\n");
    expect(sha256("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    const output = path.join(root, "results/run");
    await reserveOutput(output);
    await Bun.write(path.join(output, "keep.txt"), "previous result");
    expect(reserveOutput(output)).rejects.toThrow("Output already exists");
    expect(await Bun.file(path.join(output, "keep.txt")).text()).toBe(
      "previous result"
    );
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});

test("case snapshots freeze image bytes and reject unknown cases before requests", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "skill-issue-eval-cases-"));
  try {
    await Bun.write(
      path.join(root, "evals/cases.json"),
      JSON.stringify([fixture()])
    );
    // Image decoding is the API's job; this boundary identifies PNG/JPEG and freezes bytes.
    await Bun.write(
      path.join(root, "evals/code.png"),
      Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])
    );
    const cases = await freezeCases(root, []);
    await Bun.write(path.join(root, "evals/code.png"), "changed");
    expect(cases[0]?.input[0]).toMatchObject({
      content: [
        { type: "input_text" },
        {
          image_url: "data:image/png;base64,iVBORw0KGgo=",
          type: "input_image",
        },
      ],
    });
    expect(freezeCases(root, ["missing"])).rejects.toThrow("Unknown case IDs");
    expect(freezeCases(root, [])).rejects.toThrow("expected a PNG or JPEG");
  } finally {
    await rm(root, { force: true, recursive: true });
  }
});
