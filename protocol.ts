import * as v from "valibot";

export const maxPacketLength = 4_000_000;
const sequence = v.pipe(v.number(), v.safeInteger(), v.minValue(1));
const encoded = v.pipe(v.string(), v.regex(/^[A-Za-z0-9+/]+=*$/u));
const answer = v.object({
  id: v.string(),
  language: v.string(),
  status: v.picklist(["generating", "complete", "incomplete", "failed"]),
  text: v.string(),
});
const command = v.object({
  answerID: v.nullish(v.string()),
  direction: v.picklist([-1, 1]),
  id: sequence,
});
export const ViewStateSchema = v.object({
  answers: v.array(answer),
  audioEnabled: v.optional(v.boolean(), true),
  canAnswer: v.boolean(),
  command: v.nullish(command),
  error: v.string(),
  fontSize: v.pipe(v.number(), v.finite(), v.minValue(16), v.maxValue(40)),
  live: v.boolean(),
  modifiers: v.string(),
  selectedID: v.nullish(v.string()),
  selection: v.pipe(v.number(), v.safeInteger(), v.minValue(0)),
  selectionRequest: v.nullish(v.object({ client: v.string(), id: sequence })),
  version: v.literal(3),
});
export type ViewState = v.InferOutput<typeof ViewStateSchema>;

export const StatePacketSchema = v.object({
  box: v.pipe(encoded, v.maxLength(maxPacketLength)),
  seq: sequence,
  type: v.literal("state"),
});
export type Packet = v.InferOutput<typeof StatePacketSchema>;
const ViewerStatePacketSchema = v.object({
  ...StatePacketSchema.entries,
  publisher: v.nullable(v.string()),
});
export type ViewerPacket = v.InferOutput<typeof ViewerStatePacketSchema>;
export const AckPacketSchema = v.object({
  box: v.pipe(encoded, v.maxLength(1024)),
  seq: sequence,
  type: v.literal("ack"),
});
export const SelectPacketSchema = v.object({
  box: v.pipe(encoded, v.maxLength(1024)),
  id: sequence,
  publisher: v.string(),
  type: v.literal("select"),
});
const viewerMessage = v.variant("type", [
  v.object({ client: v.string(), type: v.literal("ready") }),
  ViewerStatePacketSchema,
  v.object({ type: v.literal("offline") }),
  v.object({ type: v.literal("ended") }),
]);
const envelope = v.object({ type: v.nonOptional(v.unknown()) });
export function parseViewerMessage(input: unknown) {
  const message = v.parse(envelope, input);
  // Ignore unrelated message types, but validate every recognized packet.
  return typeof message.type === "string" &&
    ["ready", "state", "offline", "ended"].includes(message.type)
    ? v.parse(viewerMessage, input)
    : undefined;
}
const linkSecret = v.pipe(v.string(), v.regex(/^[\w-]{43}$/u));
export const ViewerLinkSchema = v.strictTuple([
  v.pipe(
    v.string(),
    v.regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u)
  ),
  linkSecret,
  linkSecret,
]);
