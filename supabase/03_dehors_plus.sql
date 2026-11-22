-- =====================================================================
--  Dehors : Dehors+ (abonnement, Fondateur, Pass Saison)
-- =====================================================================
--  - Statut par compte : free, plus (avec une date de fin) ou founder (à vie).
--  - Badge « + » public au classement (players.plus), tenu à jour par la base.
--  - Pass Saison : accès au parcours premium d'une seule saison.
--  - Liste d'attente tant que le paiement n'est pas ouvert.
--  - Compteurs anonymes par jour et par étape (aucune donnée personnelle).
--  Les écritures liées au paiement passent par des fonctions réservées au
--  serveur (service_role) : l'app ne peut pas se donner Dehors+ elle-même.
-- =====================================================================

alter table public.accounts
  add column plan        text not null default 'free' check (plan in ('free', 'plus', 'founder')),
  add column plan_until  timestamptz,
  add column plan_source text check (plan_source in ('stripe', 'gift')),
  add column plan_started timestamptz,              -- début de l'abonnement en cours (délai de rétractation)
  add column stripe_customer_id     text unique,
  add column stripe_subscription_id text unique;

alter table public.players add column plus boolean not null default false;

create table public.season_passes (
  account_id uuid not null references public.accounts (id) on delete cascade,
  season     text not null check (season ~ '^(hiver|printemps|ete|automne)-[0-9]{4}$'),
  created_at timestamptz not null default now(),
  primary key (account_id, season)
);

create table public.plus_interest (
  account_id uuid primary key references public.accounts (id) on delete cascade,
  offer      text not null check (offer in ('annual', 'monthly', 'founder', 'pass')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.funnel (
  day  date not null default current_date,
  step text not null check (step ~ '^[a-z0-9_:]{2,40}$'),
  n    integer not null default 0,
  primary key (day, step)
);

alter table public.season_passes enable row level security;
alter table public.plus_interest enable row level security;
alter table public.funnel        enable row level security;
revoke all on public.season_passes, public.plus_interest, public.funnel from anon, authenticated;

-- ---------------------------------------------------------------------
--  Outils internes
-- ---------------------------------------------------------------------
create or replace function private.is_plus(p_id uuid)
returns boolean
language sql stable
set search_path = ''
as $$
  select exists (select 1 from public.accounts a
                 where a.id = p_id
                   and (a.plan = 'founder' or (a.plan = 'plus' and a.plan_until > now())))
$$;

-- Recalcule le badge public d'un compte
create or replace function private.sync_plus(p_id uuid)
returns void
language sql
set search_path = ''
as $$
  update public.players p set plus = private.is_plus(p_id)
  where p.id = p_id and p.plus is distinct from private.is_plus(p_id)
$$;

revoke all on function private.is_plus(uuid), private.sync_plus(uuid) from public;

-- ---------------------------------------------------------------------
--  Ouvrir son compte : on ajoute le statut Dehors+ et les passes
-- ---------------------------------------------------------------------
create or replace function public.me(p_key text, p_rev integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := private.account_of(p_key);
  r    jsonb;
begin
  if v_id is null then
    return null;
  end if;
  update public.accounts set seen_at = now()
  where id = v_id and seen_at < now() - interval '1 hour';
  perform private.sync_plus(v_id);

  select jsonb_build_object(
           'id', p.id,
           'pseudo', p.pseudo,
           'rev', g.rev,
           'admin', private.is_admin(v_id),
           'email', a.auth_email,
           'provider', a.auth_provider,
           'plus', private.is_plus(v_id),
           'plan', a.plan,
           'plan_until', a.plan_until,
           'plan_started', a.plan_started,
           'managed', a.stripe_customer_id is not null,
           'subscribed', a.stripe_subscription_id is not null,
           'passes', coalesce((select jsonb_agg(sp.season order by sp.season) from public.season_passes sp where sp.account_id = v_id), '[]'::jsonb))
         || case when p_rev is distinct from g.rev then jsonb_build_object('state', g.state) else '{}'::jsonb end
    into r
  from public.players p
  join public.progress g on g.id = p.id
  join public.accounts a on a.id = p.id
  where p.id = v_id;
  return r;
end
$$;

-- ---------------------------------------------------------------------
--  Fonctions publiques
-- ---------------------------------------------------------------------

-- Places Fondateur restantes (300 au total)
create or replace function public.plus_status()
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('founder_left',
         greatest(0, 300 - (select count(*) from public.accounts a where a.plan = 'founder')))
$$;

-- Liste d'attente : « préviens-moi au lancement »
create or replace function public.plus_interest(p_key text, p_offer text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := private.account_of(p_key);
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'key');
  end if;
  if p_offer not in ('annual', 'monthly', 'founder', 'pass') then
    return jsonb_build_object('ok', false, 'error', 'offer');
  end if;
  insert into public.plus_interest (account_id, offer) values (v_id, p_offer)
  on conflict (account_id) do update set offer = excluded.offer, updated_at = now();
  return jsonb_build_object('ok', true);
end
$$;

-- Compteurs anonymes : une étape du parcours, +1 pour aujourd'hui
create or replace function public.track(p_step text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_step is null or p_step !~ '^(open|onboarded|unlock5|secure_view|secured|plus_view:[a-z_]{2,20}|plus_interest:[a-z]{4,10}|checkout:[a-z]{4,10})$' then
    return;
  end if;
  insert into public.funnel (day, step, n) values (current_date, p_step, 1)
  on conflict (day, step) do update set n = public.funnel.n + 1;
end
$$;

-- Offrir Dehors+ (administrateurs) : tests, concours, partenaires
create or replace function public.admin_gift_plus(p_key text, p_pseudo text, p_days integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin uuid := private.account_of(p_key);
  v_id    uuid;
begin
  if not private.is_admin(v_admin) then
    return jsonb_build_object('ok', false, 'error', 'admin');
  end if;
  if p_days is null or p_days < 0 or p_days > 3660 then
    return jsonb_build_object('ok', false, 'error', 'days');
  end if;
  select p.id into v_id from public.players p where lower(p.pseudo) = lower(btrim(p_pseudo));
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'pseudo');
  end if;
  update public.accounts a
     set plan = case when p_days = 0 then 'free' else 'plus' end,
         plan_until = case when p_days = 0 then null else greatest(coalesce(a.plan_until, now()), now()) + make_interval(days => p_days) end,
         plan_source = case when p_days = 0 then null else 'gift' end
   where a.id = v_id and a.plan <> 'founder' and a.stripe_subscription_id is null;
  perform private.sync_plus(v_id);
  return jsonb_build_object('ok', true, 'plus', private.is_plus(v_id),
                            'until', (select a.plan_until from public.accounts a where a.id = v_id));
end
$$;

-- Tableau de bord des administrateurs : membres, liste d'attente, parcours des 7 derniers jours
create or replace function public.admin_plus_stats(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_admin(private.account_of(p_key)) then
    return jsonb_build_object('ok', false, 'error', 'admin');
  end if;
  return jsonb_build_object(
    'ok', true,
    'members',  (select count(*) from public.accounts a where a.plan = 'plus' and a.plan_until > now()),
    'founders', (select count(*) from public.accounts a where a.plan = 'founder'),
    'passes',   (select count(*) from public.season_passes),
    'waitlist', coalesce((select jsonb_object_agg(t.offer, t.n)
                          from (select i.offer, count(*) as n from public.plus_interest i group by i.offer) t), '{}'::jsonb),
    'funnel',   coalesce((select jsonb_object_agg(t.step, t.n)
                          from (select f.step, sum(f.n)::integer as n from public.funnel f
                                where f.day > current_date - 7 group by f.step) t), '{}'::jsonb));
end
$$;

-- ---------------------------------------------------------------------
--  Réservé au serveur de paiement (Stripe, via service_role)
-- ---------------------------------------------------------------------

-- Retrouver un compte (et son e-mail) à partir de la clé du joueur
create or replace function public.pay_account(p_key text)
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('id', a.id, 'email', a.auth_email, 'customer', a.stripe_customer_id,
                            'subscription', a.stripe_subscription_id, 'plan', a.plan, 'plan_until', a.plan_until,
                            'plan_started', a.plan_started, 'plus', private.is_plus(a.id), 'pseudo', p.pseudo,
                            'passes', coalesce((select jsonb_agg(sp.season) from public.season_passes sp where sp.account_id = a.id), '[]'::jsonb))
  from public.accounts a join public.players p on p.id = a.id
  where a.id = private.account_of(p_key)
$$;

-- Appliquer un événement de paiement : abonnement, Fondateur, Pass Saison, fin d'abonnement
create or replace function public.pay_apply(p_account uuid, p_kind text, p_until timestamptz default null,
                                            p_customer text default null, p_subscription text default null,
                                            p_season text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.accounts a where a.id = p_account) then
    return jsonb_build_object('ok', false, 'error', 'account');
  end if;
  if p_customer is not null then
    update public.accounts set stripe_customer_id = p_customer where id = p_account;
  end if;
  if p_kind = 'subscription' then
    update public.accounts a
       set plan = case when a.plan = 'founder' then 'founder' else 'plus' end,
           plan_until = p_until, plan_source = 'stripe',
           plan_started = case when a.stripe_subscription_id is distinct from coalesce(p_subscription, a.stripe_subscription_id)
                                 or a.plan_started is null then now() else a.plan_started end,
           stripe_subscription_id = coalesce(p_subscription, a.stripe_subscription_id)
     where a.id = p_account;
  elsif p_kind = 'subscription_end' then
    update public.accounts a
       set plan = case when a.plan = 'founder' then 'founder' else 'free' end,
           plan_until = case when a.plan = 'founder' then null else p_until end,
           plan_started = null,
           stripe_subscription_id = null
     where a.id = p_account and (p_subscription is null or a.stripe_subscription_id = p_subscription);
  elsif p_kind = 'founder' then
    update public.accounts set plan = 'founder', plan_until = null, plan_source = 'stripe' where id = p_account;
  elsif p_kind = 'pass' then
    if coalesce(p_season, '') !~ '^(hiver|printemps|ete|automne)-[0-9]{4}$' then
      return jsonb_build_object('ok', false, 'error', 'season');
    end if;
    insert into public.season_passes (account_id, season) values (p_account, p_season) on conflict do nothing;
  else
    return jsonb_build_object('ok', false, 'error', 'kind');
  end if;
  perform private.sync_plus(p_account);
  return jsonb_build_object('ok', true, 'plus', private.is_plus(p_account));
end
$$;

-- Retrouver un compte par son client Stripe (pour les renouvellements et résiliations)
create or replace function public.pay_account_by_customer(p_customer text)
returns uuid
language sql stable
security definer
set search_path = ''
as $$
  select a.id from public.accounts a where a.stripe_customer_id = p_customer
$$;

-- Supprimer son compte : impossible tant qu'un abonnement payant tourne
create or replace function public.delete_account(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id   uuid := private.account_of(p_key);
  v_auth uuid;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'key');
  end if;
  if exists (select 1 from public.accounts a where a.id = v_id and a.stripe_subscription_id is not null) then
    return jsonb_build_object('ok', false, 'error', 'subscription');
  end if;
  select a.auth_id into v_auth from public.accounts a where a.id = v_id;
  delete from public.accounts where id = v_id;
  if v_auth is not null then
    begin
      delete from auth.users where id = v_auth;
    exception when others then
      null;
    end;
  end if;
  return jsonb_build_object('ok', true);
end
$$;

-- ---------------------------------------------------------------------
--  Vitrine du profil : 3 hauts faits, 6 pour les membres Dehors+
-- ---------------------------------------------------------------------
alter table public.players drop constraint if exists players_showcase_check;
alter table public.players add constraint players_showcase_check
  check (jsonb_typeof(showcase) = 'array' and jsonb_array_length(showcase) <= 6
         and octet_length(showcase::text) <= 3000);

create or replace function public.save(p_key text, p_player jsonb default null,
                                       p_state jsonb default null, p_rev integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid := private.account_of(p_key);
  v_rev   integer;
  v_pts   integer;
  v_color text;
  v_sc    jsonb;
  v_last  jsonb;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'key');
  end if;

  if p_state is not null then
    if jsonb_typeof(p_state) <> 'object' or octet_length(p_state::text) > 400000 then
      return jsonb_build_object('ok', false, 'error', 'state');
    end if;
    update public.progress
       set state = p_state, rev = rev + 1, updated_at = now()
     where id = v_id and rev = coalesce(p_rev, -1)
    returning rev into v_rev;
    if v_rev is null then
      return (select jsonb_build_object('ok', false, 'error', 'conflict', 'state', g.state, 'rev', g.rev)
              from public.progress g where g.id = v_id);
    end if;
  end if;

  if p_player is not null and jsonb_typeof(p_player) = 'object' then
    v_pts   := private.try_int(p_player ->> 'points', 0, 1000000);
    v_color := p_player ->> 'color';
    v_sc    := case when jsonb_typeof(p_player -> 'showcase') = 'array'
                     and octet_length((p_player -> 'showcase')::text) <= 3000
                    then jsonb_path_query_array(p_player -> 'showcase',
                           (case when private.is_plus(v_id) then '$[0 to 5]' else '$[0 to 2]' end)::jsonpath)
                    else '[]'::jsonb end;
    v_last  := case when jsonb_typeof(p_player -> 'last') = 'object'
                     and octet_length((p_player -> 'last')::text) <= 300
                    then p_player -> 'last' end;
    update public.players set
      avatar      = coalesce(nullif(left(p_player ->> 'avatar', 16), ''), avatar),
      color       = case when v_color ~ '^#[0-9A-Fa-f]{6}$' then v_color else color end,
      title       = left(coalesce(p_player ->> 'title', ''), 40),
      bio         = left(coalesce(p_player ->> 'bio', ''), 90),
      showcase    = v_sc,
      points_at   = case when v_pts <> points then now() else points_at end,
      points      = v_pts,
      got         = private.try_int(p_player ->> 'count', 0, 10000),
      last_unlock = coalesce(v_last, last_unlock),
      since       = coalesce(private.try_date(p_player ->> 'since'), since),
      updated_at  = now()
    where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'rev', v_rev);
end
$$;

-- ---------------------------------------------------------------------
--  Droits
-- ---------------------------------------------------------------------
revoke all on function
  public.plus_status(), public.plus_interest(text, text), public.track(text),
  public.admin_gift_plus(text, text, integer), public.admin_plus_stats(text),
  public.pay_account(text), public.pay_apply(uuid, text, timestamptz, text, text, text),
  public.pay_account_by_customer(text)
  from public, anon, authenticated;
grant execute on function
  public.plus_status(), public.plus_interest(text, text), public.track(text),
  public.admin_gift_plus(text, text, integer), public.admin_plus_stats(text)
  to anon, authenticated;
grant execute on function
  public.pay_account(text), public.pay_apply(uuid, text, timestamptz, text, text, text),
  public.pay_account_by_customer(text)
  to service_role;

-- Le classement lit maintenant aussi le badge
grant select on public.players to anon, authenticated;
