import { buildEmail, type ReportPayload } from "./handler.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (req.headers.get("Authorization") !== `Bearer ${Deno.env.get("NOTIFY_REPORT_SECRET")}`) {
    return new Response("unauthorized", { status: 401 });
  }
  let payload: ReportPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }
  const { subject, text } = buildEmail(payload, Deno.env.get("DASHBOARD_URL") ?? "");
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`,
    },
    body: JSON.stringify({
      from: Deno.env.get("NOTIFY_FROM_EMAIL") ?? "onboarding@resend.dev",
      to: Deno.env.get("OPERATOR_EMAIL"),
      subject,
      text,
    }),
  });
  return new Response(res.ok ? "ok" : "send failed", { status: res.ok ? 200 : 502 });
});
