import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

// إرسال إشعارات الجهاز. لا يقبل إلا طلباً يحمل السر المحفوظ في جدول push_config (يستدعيه المجدوِل داخل قاعدة البيانات).
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: cfgRows, error: ce } = await sb.from("push_config").select("key,value");
  if (ce || !cfgRows) return new Response("cfg", { status: 500 });
  const cfg: Record<string, string> = {};
  cfgRows.forEach((r: any) => (cfg[r.key] = r.value));
  const got = req.headers.get("x-push-secret") || "";
  if (!cfg.push_secret || got.length !== cfg.push_secret.length || got !== cfg.push_secret) return new Response("denied", { status: 401 });
  let body: any;
  try { body = await req.json(); } catch { return new Response("json", { status: 400 }); }
  const items: any[] = Array.isArray(body?.items) ? body.items.slice(0, 300) : [];
  if (!items.length) return new Response(JSON.stringify({ sent: 0 }), { headers: { "Content-Type": "application/json" } });
  webpush.setVapidDetails(cfg.vapid_subject, cfg.vapid_public, cfg.vapid_private);
  const ids = [...new Set(items.map((i) => i.user_id))];
  const { data: subs } = await sb.from("push_subscriptions").select("id,user_id,endpoint,p256dh,auth").in("user_id", ids);
  let sent = 0, dead: string[] = [];
  await Promise.all(items.flatMap((it) => (subs || []).filter((s: any) => s.user_id === it.user_id).map(async (s: any) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify({ title: it.title, body: it.body || "", url: it.url || "", tag: it.tag || "" }),
        { TTL: 6 * 3600, urgency: "high" },
      );
      sent++;
    } catch (e: any) {
      if (e && (e.statusCode === 404 || e.statusCode === 410)) dead.push(s.id);
    }
  })));
  if (dead.length) await sb.from("push_subscriptions").delete().in("id", dead);
  return new Response(JSON.stringify({ sent, removed: dead.length }), { headers: { "Content-Type": "application/json" } });
});
