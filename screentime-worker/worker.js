// Mac screen time endpoint for The System. Runs as a Cloudflare Worker on the free plan.
//
// Bindings (set in the Cloudflare dashboard, see docs/FOCUS_TRACKING.md):
//   SCREEN  KV namespace that holds one record per quest day.
//   TOKEN   Secret. Every request except /health must send "Authorization: Bearer <TOKEN>".
//
// POST /v1/screentime/mac
//   {"deviceID": "...", "deviceName": "Work MacBook", "dayKey": "2026-10-26", "minutes": 280, "active": "<base64>"}
//   Each Mac sends its running total for the quest day. A new value replaces that Mac's old one.
//   "active" (optional) is a bitmap of the quest day's minutes: bit i is minute i after 5:00 local,
//   byte i >> 3, bit 1 << (i & 7). It lets two Macs used in the same minute count that minute once.
// GET  /v1/integrations/screentime/snapshot?day=2026-10-26
//   {"available": true, "dayKey": "2026-10-26", "workMinutes": 412, "active": "<base64>", "devices": [...]}
//   workMinutes counts each active minute once across every Mac, plus any minutes a Mac could not place
//   in its bitmap. "active" is the merged bitmap; the iPhone uses it to find phone time that overlaps.
// GET  /health
//   {"ok": true}. No token, so a work Mac can test that its network reaches the Worker.

const DAY_KEY = /^\d{4}-\d{2}-\d{2}$/;
const KEEP_SECONDS = 90 * 24 * 60 * 60;
const MAX_MINUTES = 24 * 60;
// 1,504 minutes: a 25-hour quest day (the fall DST change) fits.
const ACTIVE_BYTES = 188;

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
  const active = body.active === undefined ? undefined : decodeActive(body.active);
  if (active === null) return json({ error: "bad active" }, 400);

  const key = `day:${dayKey}`;
  const day = (await env.SCREEN.get(key, "json")) || { devices: {} };
  day.devices[deviceID] = {
    name: typeof deviceName === "string" ? deviceName.slice(0, 80) : "Mac",
    minutes,
    ...(active ? { active: body.active } : {}),
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
  return json({ available: true, dayKey, workMinutes: total(day), active: encodeActive(merged(day)), devices });
}

// Each minute counts once across all Macs. A Mac's minutes outside its bitmap (sent before it had one,
// or minutes too short to mark) still count, so the total is never below what the Mac counted by itself.
function total(day) {
  let unplaced = 0;
  for (const device of Object.values(day.devices)) {
    const own = device.active ? popcount(decodeActive(device.active) || new Uint8Array(ACTIVE_BYTES)) : 0;
    unplaced += Math.max(0, device.minutes - own);
  }
  return Math.min(MAX_MINUTES, popcount(merged(day)) + unplaced);
}

function merged(day) {
  const bits = new Uint8Array(ACTIVE_BYTES);
  for (const device of Object.values(day.devices)) {
    const own = device.active && decodeActive(device.active);
    if (own) own.forEach((byte, index) => { bits[index] |= byte; });
  }
  return bits;
}

// Base64 of at most ACTIVE_BYTES bytes, padded to that length. Null when it is not valid.
function decodeActive(text) {
  if (typeof text !== "string" || text.length > 4 * Math.ceil(ACTIVE_BYTES / 3)) return null;
  let raw;
  try {
    raw = atob(text);
  } catch {
    return null;
  }
  if (raw.length > ACTIVE_BYTES) return null;
  const bits = new Uint8Array(ACTIVE_BYTES);
  for (let index = 0; index < raw.length; index++) bits[index] = raw.charCodeAt(index);
  return bits;
}

function encodeActive(bits) {
  return btoa(String.fromCharCode(...bits));
}

function popcount(bits) {
  let count = 0;
  for (let byte of bits) {
    while (byte) {
      count += byte & 1;
      byte >>= 1;
    }
  }
  return count;
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
