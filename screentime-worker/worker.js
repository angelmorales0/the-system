// Mac screen time endpoint for The System. Runs as a Cloudflare Worker on the free plan.
//
// Bindings (set in the Cloudflare dashboard, see docs/FOCUS_TRACKING.md):
//   SCREEN  KV namespace that holds one record per quest day.
//   TOKEN   Secret. Every request except /health must send "Authorization: Bearer <TOKEN>".
//
// POST /v1/screentime/mac
//   {"deviceID": "...", "deviceName": "Work MacBook", "dayKey": "2026-10-26", "minutes": 280}
//   Each Mac sends its running total for the quest day. A new value replaces that Mac's old one.
// GET  /v1/integrations/screentime/snapshot?day=2026-10-26
//   {"available": true, "dayKey": "2026-10-26", "workMinutes": 412, "devices": [...]}
//   workMinutes adds every Mac together. The iPhone app shows it on the Screen Time quest's Work line.
// GET  /health
//   {"ok": true}. No token, so a work Mac can test that its network reaches the Worker.

const DAY_KEY = /^\d{4}-\d{2}-\d{2}$/;
const KEEP_SECONDS = 90 * 24 * 60 * 60;
const MAX_MINUTES = 24 * 60;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/health") return json({ ok: true });
      if (!authorized(request, env)) return json({ error: "unauthorized" }, 401);
      if (request.method === "POST" && url.pathname === "/v1/screentime/mac") return await record(request, env);
      if (request.method === "GET" && url.pathname === "/v1/integrations/screentime/snapshot") return await snapshot(url, env);
      return json({ error: "not found" }, 404);
    } catch (error) {
      return json({ error: "server error" }, 500);
    }
  },
};

function authorized(request, env) {
  const header = request.headers.get("Authorization") || "";
  return Boolean(env.TOKEN) && header === `Bearer ${env.TOKEN}`;
}

async function record(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "body must be JSON" }, 400);
  }
  const { deviceID, deviceName, dayKey, minutes } = body || {};
  if (typeof deviceID !== "string" || deviceID.length === 0 || deviceID.length > 64) return json({ error: "bad deviceID" }, 400);
  if (typeof dayKey !== "string" || !DAY_KEY.test(dayKey)) return json({ error: "bad dayKey" }, 400);
  if (!Number.isInteger(minutes) || minutes < 0 || minutes > MAX_MINUTES) return json({ error: "bad minutes" }, 400);

  const key = `day:${dayKey}`;
  const day = (await env.SCREEN.get(key, "json")) || { devices: {} };
  day.devices[deviceID] = {
    name: typeof deviceName === "string" ? deviceName.slice(0, 80) : "Mac",
    minutes,
    updatedAt: new Date().toISOString(),
  };
  await env.SCREEN.put(key, JSON.stringify(day), { expirationTtl: KEEP_SECONDS });
  return json({ ok: true, dayKey, workMinutes: total(day) });
}

async function snapshot(url, env) {
  const dayKey = url.searchParams.get("day") || "";
  if (!DAY_KEY.test(dayKey)) return json({ error: "bad day" }, 400);
  const day = await env.SCREEN.get(`day:${dayKey}`, "json");
  if (!day) return json({ available: false, dayKey, workMinutes: null, devices: [] });
  const devices = Object.values(day.devices).map(({ name, minutes, updatedAt }) => ({ name, minutes, updatedAt }));
  return json({ available: true, dayKey, workMinutes: total(day), devices });
}

function total(day) {
  return Object.values(day.devices).reduce((sum, device) => sum + device.minutes, 0);
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
