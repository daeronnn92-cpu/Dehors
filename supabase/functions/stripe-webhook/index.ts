// =====================================================================
//  Dehors+ : ce que Stripe nous annonce (paiements, essais, renouvellements,
//  résiliations), reporté sur le compte du joueur.
//  Chaque appel est signé par Stripe : sans signature valide, rien ne change.
//  Secrets à définir dans Supabase : STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET.
// =====================================================================

const STRIPE_API = Deno.env.get("STRIPE_API_BASE") ?? "https://api.stripe.com";
const STRIPE_VERSION = "2025-03-31.basil";
const TOLERANCE = 300; // secondes

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

function dbKey(): Record<string, string> {
  try {
    const k = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (k && k.default) return { apikey: k.default };
  } catch (_) { /* clé ancienne ci-dessous */ }
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return { apikey: legacy, Authorization: "Bearer " + legacy };
}
async function rpc(fn: string, args: Obj) {
  const r = await fetch(Deno.env.get("SUPABASE_URL") + "/rest/v1/rpc/" + fn, {
    method: "POST",
    headers: { ...dbKey(), "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(fn + " " + r.status + " " + t.slice(0, 300));
  return t ? JSON.parse(t) : null;
}
async function stripeGet(path: string) {
  const r = await fetch(STRIPE_API + "/v1/" + path, {
    headers: { Authorization: "Bearer " + Deno.env.get("STRIPE_SECRET_KEY"), "Stripe-Version": STRIPE_VERSION },
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error("stripe " + path + " " + r.status + " " + ((j.error && j.error.message) || ""));
  return j;
}

// Signature Stripe : HMAC-SHA256 de « horodatage.corps », comparée sans fuite de temps
function same(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function signed(body: string, header: string, secret: string) {
  let t = "";
  const v1: string[] = [];
  for (const part of header.split(",")) {
    const i = part.indexOf("="), k = part.slice(0, i).trim(), v = part.slice(i + 1).trim();
    if (k === "t") t = v;
    if (k === "v1") v1.push(v);
  }
  if (!/^\d+$/.test(t) || !v1.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > TOLERANCE) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(t + "." + body)));
  const hex = Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
  return v1.some((s) => same(s, hex));
}

const idOf = (x: unknown) => (typeof x === "string" ? x : x && typeof x === "object" ? (x as Obj).id ?? null : null);
const iso = (s: number) => new Date(s * 1000).toISOString();

async function accountOf(sub: Obj, hint?: string | null) {
  if (hint) return hint;
  if (sub.metadata && sub.metadata.account_id) return sub.metadata.account_id;
  const cus = idOf(sub.customer);
  return cus ? await rpc("pay_account_by_customer", { p_customer: cus }) : null;
}
// Un abonnement : actif (essai compris) jusqu'à la fin de sa période, sinon terminé
async function applySub(sub: Obj, hint?: string | null) {
  const account = await accountOf(sub, hint);
  if (!account) return;
  const customer = idOf(sub.customer);
  if (["trialing", "active", "past_due"].includes(sub.status)) {
    const end = sub.current_period_end ?? (sub.items && sub.items.data && sub.items.data[0] && sub.items.data[0].current_period_end) ?? sub.trial_end;
    await rpc("pay_apply", { p_account: account, p_kind: "subscription", p_until: iso(end), p_customer: customer, p_subscription: sub.id });
  } else {
    const end = sub.ended_at ?? sub.canceled_at ?? Math.floor(Date.now() / 1000);
    await rpc("pay_apply", { p_account: account, p_kind: "subscription_end", p_until: iso(end), p_customer: customer, p_subscription: sub.id });
  }
}

async function handle(ev: Obj) {
  const o: Obj = (ev.data && ev.data.object) || {};
  switch (ev.type) {
    case "checkout.session.completed":
    case "checkout.session.async_payment_succeeded": {
      const account = o.client_reference_id || (o.metadata && o.metadata.account_id);
      if (!account) return;
      const customer = idOf(o.customer);
      if (o.mode === "payment") {
        if (o.payment_status !== "paid") return;   // paiement différé : on attend sa confirmation
        const offer = o.metadata && o.metadata.offer;
        if (offer === "founder") await rpc("pay_apply", { p_account: account, p_kind: "founder", p_customer: customer });
        else if (offer === "pass") await rpc("pay_apply", { p_account: account, p_kind: "pass", p_customer: customer, p_season: o.metadata.season });
        return;
      }
      const sid = idOf(o.subscription);
      if (o.mode === "subscription" && sid) await applySub(await stripeGet("subscriptions/" + sid), account);
      return;
    }
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
    case "customer.subscription.paused":
    case "customer.subscription.resumed":
      await applySub(o);
      return;
    case "invoice.paid": {
      const sid = idOf(o.subscription ?? (o.parent && o.parent.subscription_details && o.parent.subscription_details.subscription));
      if (sid) await applySub(await stripeGet("subscriptions/" + sid));
      return;
    }
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
  if (!secret || !Deno.env.get("STRIPE_SECRET_KEY")) return new Response("config", { status: 503 });
  const body = await req.text();
  if (!(await signed(body, req.headers.get("stripe-signature") ?? "", secret))) return new Response("signature", { status: 400 });
  let ev: Obj;
  try { ev = JSON.parse(body); } catch (_) { return new Response("json", { status: 400 }); }
  try {
    await handle(ev);
  } catch (e) {
    console.error(ev.type, String(e));
    return new Response("error", { status: 500 });   // Stripe réessaiera plus tard
  }
  return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
});
