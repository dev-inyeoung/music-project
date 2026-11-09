import { assert, assertEquals } from "jsr:@std/assert@1";
import { buildEmail } from "./handler.ts";

const id = "11111111-2222-3333-4444-555555555555";
const url = "https://dashboard.example.com/entries";

Deno.test("subject marks hidden when report_count >= 3", () => {
  const { subject } = buildEmail({ entry_id: id, reason: "spam", report_count: 3 }, url);
  assert(subject.includes("[숨김됨]"));
});

Deno.test("subject has no hidden marker below threshold", () => {
  const { subject } = buildEmail({ entry_id: id, reason: null, report_count: 2 }, url);
  assertEquals(subject.includes("[숨김됨]"), false);
});

Deno.test("text includes entry_id, dashboard url and reason", () => {
  const { text } = buildEmail({ entry_id: id, reason: "욕설", report_count: 1 }, url);
  assert(text.includes(id));
  assert(text.includes(url));
  assert(text.includes("욕설"));
});
