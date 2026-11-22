// =====================================================================
//  Dehors+ côté serveur : ouvrir le paiement Stripe, le portail client
//  (gérer, résilier) et la rétractation.
//  L'app envoie la clé du joueur : c'est elle qui identifie le compte.
//  La clé secrète Stripe reste ici, elle n'est jamais envoyée à l'app.
//  Secrets à définir dans Supabase : STRIPE_SECRET_KEY.
// =====================================================================

const SITE = (Deno.env.get("SITE_URL") ?? "https://dehors-sandy.vercel.app/").replace(/\/?$/, "/");
const STRIPE_API = Deno.env.get("STRIPE_API_BASE") ?? "https://api.stripe.com";
const STRIPE_VERSION = "2025-03-31.basil";
const TRIAL_DAYS = 14;
const WITHDRAW_DAYS = 14;
const LOOKUP: Record<string, string> = {
  annual: "dehors_plus_annual",
  monthly: "dehors_plus_monthly",
  founder: "dehors_founder",
  pass: "dehors_pass_season",
};
const KEY_RE = /^[0-9A-HJKMNP-TV-Z]{16}$/;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type, authorization, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// ---------- Base de données (fonctions réservées au serveur) ----------
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

// ---------- Stripe (API REST, sans dépendance) ----------
function flat(o: Obj, pre = "", out: [string, string][] = []): [string, string][] {
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || v === null) continue;
    const key = pre ? `${pre}[${k}]` : k;
    if (Array.isArray(v)) v.forEach((x, i) => (typeof x === "object" ? flat(x, `${key}[${i}]`, out) : out.push([`${key}[${i}]`, String(x)])));
    else if (typeof v === "object") flat(v, key, out);
    else out.push([key, String(v)]);
  }
  return out;
}
async function stripe(method: string, path: string, params: Obj = {}) {
  const q = new URLSearchParams(flat(params)).toString();
  const init: RequestInit = {
    method,
    headers: { Authorization: "Bearer " + Deno.env.get("STRIPE_SECRET_KEY"), "Stripe-Version": STRIPE_VERSION },
  };
  let url = STRIPE_API + "/v1/" + path;
  if (method === "GET" || method === "DELETE") { if (q) url += "?" + q; }
  else { (init.headers as Obj)["Content-Type"] = "application/x-www-form-urlencoded"; init.body = q; }
  const r = await fetch(url, init);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error("stripe " + path + " " + r.status + " " + ((j.error && j.error.message) || ""));
  return j;
}
const prices: Record<string, string> = {};
async function priceOf(offer: string) {
  if (prices[offer]) return prices[offer];
  const r = await stripe("GET", "prices", { lookup_keys: [LOOKUP[offer]], active: true, limit: 1 });
  if (!r.data || !r.data[0]) throw new Error("prix introuvable : " + LOOKUP[offer]);
  return (prices[offer] = r.data[0].id);
}

// Même découpage des saisons que l'app
function seasonKey(t = Date.now()) {
  const d = new Date(t), y = d.getUTCFullYear(), md = (d.getUTCMonth() + 1) * 100 + d.getUTCDate();
  if (md >= 1221 || md < 320) return "hiver-" + (md >= 1221 ? y : y - 1);
  if (md < 621) return "printemps-" + y;
  if (md < 923) return "ete-" + y;
  return "automne-" + y;
}

// ---------- Paiement : Stripe Checkout ----------
async function checkout(acct: Obj, offer: string) {
  if (!LOOKUP[offer]) return json({ error: "offer" }, 400);
  if (!acct.email) return json({ error: "email" }, 400);          // il faut un compte sécurisé
  const season = seasonKey();
  if (offer === "pass") {
    if (acct.plus || (acct.passes || []).includes(season)) return json({ error: "already" }, 409);
  } else if (acct.plus) return json({ error: "already" }, 409);
  if (offer === "founder") {
    const st = await rpc("plus_status", {});
    if (!st || !(st.founder_left > 0)) return json({ error: "sold_out" }, 409);
  }
  const sub = offer === "annual" || offer === "monthly";
  let trial = sub;                                                  // un seul essai gratuit par compte
  if (sub && acct.customer) {
    const l = await stripe("GET", "subscriptions", { customer: acct.customer, status: "all", limit: 1 });
    if (l.data && l.data.length) trial = false;
  }
  const meta: Obj = { account_id: acct.id, offer };
  if (offer === "pass") meta.season = season;
  const p: Obj = {
    mode: sub ? "subscription" : "payment",
    line_items: [{ price: await priceOf(offer), quantity: 1 }],
    success_url: SITE + "?plus=ok",
    cancel_url: SITE + "?plus=cancel",
    client_reference_id: acct.id,
    metadata: meta,
    locale: "fr",
    allow_promotion_codes: true,
  };
  if (acct.customer) p.customer = acct.customer;
  else { p.customer_email = acct.email; if (!sub) p.customer_creation = "always"; }
  if (sub) {
    p.subscription_data = { metadata: meta, ...(trial ? { trial_period_days: TRIAL_DAYS } : {}) };
    p.custom_text = { submit: { message: trial
      ? "Rien n'est prélevé pendant 14 jours. Tu peux résilier en 3 clics depuis l'app avant la fin de l'essai."
      : "Sans engagement : tu peux résilier en 3 clics depuis l'app." } };
  } else {
    p.payment_intent_data = { metadata: meta };
    p.custom_text = { submit: { message: "Tu as demandé l'accès immédiat à Dehors+ et renoncé à ton délai de rétractation de 14 jours." } };
  }
  const s = await stripe("POST", "checkout/sessions", p);
  return json({ url: s.url, trial });
}

// ---------- Gérer ou résilier : portail client Stripe ----------
async function portal(acct: Obj, cancel: boolean) {
  if (!acct.customer) return json({ error: "customer" }, 404);
  const p: Obj = { customer: acct.customer, return_url: SITE + "?plus=portal", locale: "fr" };
  const cfg = Deno.env.get("STRIPE_PORTAL_CONFIG");
  if (cfg) p.configuration = cfg;
  if (cancel && acct.subscription) {
    p.flow_data = {
      type: "subscription_cancel",
      subscription_cancel: { subscription: acct.subscription },
      after_completion: { type: "redirect", redirect: { return_url: SITE + "?plus=portal" } },
    };
  }
  const s = await stripe("POST", "billing_portal/sessions", p);
  return json({ url: s.url });
}

// ---------- Se rétracter : dans les 14 jours, arrêt immédiat et remboursement ----------
async function refundInvoice(inv: Obj) {
  if (!inv || !(inv.amount_paid > 0)) return 0;
  let pi = inv.payment_intent ?? null;                              // anciennes versions de l'API
  if (!pi) {
    const l = await stripe("GET", "invoice_payments", { invoice: inv.id, limit: 3 });
    const pay = (l.data || []).find((x: Obj) => x.status === "paid");
    pi = pay && pay.payment ? pay.payment.payment_intent : null;
  }
  if (pi && typeof pi === "object") pi = pi.id;
  if (!pi) return 0;
  const r = await stripe("POST", "refunds", { payment_intent: pi, reason: "requested_by_customer", metadata: { motif: "retractation" } });
  return r.amount || 0;
}
async function withdraw(acct: Obj) {
  if (!acct.subscription) return json({ error: "subscription" }, 404);
  const sub = await stripe("GET", "subscriptions/" + acct.subscription, { expand: ["latest_invoice"] });
  if (Date.now() / 1000 - sub.created > WITHDRAW_DAYS * 86400) return json({ error: "late" }, 409);
  if (sub.status !== "canceled") await stripe("DELETE", "subscriptions/" + sub.id);
  const refunded = await refundInvoice(typeof sub.latest_invoice === "object" ? sub.latest_invoice : null);
  await rpc("pay_apply", { p_account: acct.id, p_kind: "subscription_end", p_until: new Date().toISOString(), p_subscription: sub.id });
  return json({ ok: true, at: new Date().toISOString(), refunded });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  if (!Deno.env.get("STRIPE_SECRET_KEY")) return json({ error: "config" }, 503);
  let b: Obj;
  try { b = await req.json(); } catch (_) { return json({ error: "body" }, 400); }
  const key = String((b && b.key) || "");
  if (!KEY_RE.test(key)) return json({ error: "key" }, 403);
  try {
    const acct = await rpc("pay_account", { p_key: key });
    if (!acct || !acct.id) return json({ error: "key" }, 403);
    if (b.action === "checkout") return await checkout(acct, String(b.offer || ""));
    if (b.action === "portal") return await portal(acct, b.flow === "cancel");
    if (b.action === "withdraw") return await withdraw(acct);
    return json({ error: "action" }, 400);
  } catch (e) {
    console.error(String(e));
    return json({ error: "server" }, 500);
  }
});
