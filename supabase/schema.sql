-- =====================================================================
--  Dehors : la base de données (Supabase / Postgres)
-- =====================================================================
--  Comptes sans e-mail ni mot de passe. Chaque joueur possède une clé
--  secrète de 16 caractères (son « code de récupération »), créée par
--  son téléphone. La base n'en garde qu'une empreinte SHA-256.
--
--  Lecture publique : le classement (players) et les lieux partenaires
--  (venues, sans leur code secret). Tout le reste passe par les
--  fonctions ci-dessous, qui vérifient la clé avant d'écrire quoi que
--  ce soit. Aucune table n'est modifiable directement depuis l'app.
--
--  Donner les droits d'administration (espace établissements) :
--    insert into public.admins (id)
--    select id from public.players where lower(pseudo) = lower('TonPseudo');
-- =====================================================================

create schema if not exists private;
revoke all on schema private from public;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------

-- Un compte = une clé (seule son empreinte est stockée)
create table public.accounts (
  id         uuid primary key default gen_random_uuid(),
  key_hash   bytea not null unique,
  created_at timestamptz not null default now(),
  seen_at    timestamptz not null default now()
);

-- Profil public, affiché au classement
create table public.players (
  id          uuid primary key references public.accounts (id) on delete cascade,
  pseudo      text not null check (char_length(pseudo) between 2 and 20),
  avatar      text not null default '🧭' check (char_length(avatar) between 1 and 16),
  color       text not null default '#C8B8F6' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  title       text not null default '' check (char_length(title) <= 40),
  bio         text not null default '' check (char_length(bio) <= 90),
  showcase    jsonb not null default '[]'
              check (jsonb_typeof(showcase) = 'array' and jsonb_array_length(showcase) <= 3
                     and octet_length(showcase::text) <= 1500),
  points      integer not null default 0 check (points between 0 and 1000000),
  got         integer not null default 0 check (got between 0 and 10000),
  last_unlock jsonb check (last_unlock is null
                     or (jsonb_typeof(last_unlock) = 'object' and octet_length(last_unlock::text) <= 300)),
  since       date,
  points_at   timestamptz not null default now(),  -- départage les égalités : le premier arrivé passe devant
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index players_pseudo_key on public.players (lower(pseudo));
create index players_rank_idx on public.players (points desc, points_at asc);

-- Progression complète, privée (accessible seulement avec la clé)
create table public.progress (
  id         uuid primary key references public.accounts (id) on delete cascade,
  state      jsonb not null default '{}' check (octet_length(state::text) <= 400000),
  rev        integer not null default 0,           -- version, pour fusionner deux appareils sans rien perdre
  updated_at timestamptz not null default now()
);

-- Lieux partenaires. « code » est public (il nomme le haut fait),
-- « secret » est imprimé sur place (QR code) et n'est jamais lisible par l'app.
create table public.venues (
  code       text primary key check (code ~ '^[a-z0-9-]{3,60}$'),
  secret     text not null unique check (secret ~ '^[0-9A-HJKMNP-TV-Z]{8}$'),
  name       text not null check (char_length(name) between 1 and 60),
  city       text not null default '' check (char_length(city) <= 40),
  cat        text not null check (cat in ('food', 'sport', 'culture', 'nature', 'luxe')),
  lat        double precision check (lat between -90 and 90),
  lng        double precision check (lng between -180 and 180),
  created_by uuid references public.accounts (id) on delete set null,
  created_at timestamptz not null default now(),
  check ((lat is null) = (lng is null))
);

-- Administrateurs (espace établissements)
create table public.admins (
  id uuid primary key references public.accounts (id) on delete cascade
);

-- ---------------------------------------------------------------------
--  Sécurité : rien n'est modifiable directement, lecture publique limitée
-- ---------------------------------------------------------------------
alter table public.accounts enable row level security;
alter table public.players  enable row level security;
alter table public.progress enable row level security;
alter table public.venues   enable row level security;
alter table public.admins   enable row level security;

revoke all on public.accounts, public.players, public.progress, public.venues, public.admins
  from anon, authenticated;

grant select on public.players to anon, authenticated;
create policy "Classement public" on public.players
  for select to anon, authenticated using (true);

grant select (code, name, city, cat, lat, lng, created_at) on public.venues to anon, authenticated;
create policy "Lieux partenaires publics" on public.venues
  for select to anon, authenticated using (true);

-- accounts, progress, admins : aucune règle d'accès, donc fermés à l'app.

-- ---------------------------------------------------------------------
--  Outils internes (schéma privé, non exposé par l'API)
-- ---------------------------------------------------------------------
create or replace function private.account_of(p_key text)
returns uuid
language sql stable
set search_path = ''
as $$
  select a.id
  from public.accounts a
  where coalesce(p_key, '') ~ '^[0-9A-HJKMNP-TV-Z]{16}$'
    and a.key_hash = sha256(convert_to(p_key, 'UTF8'))
$$;

create or replace function private.is_admin(p_id uuid)
returns boolean
language sql stable
set search_path = ''
as $$
  select p_id is not null and exists (select 1 from public.admins d where d.id = p_id)
$$;

-- Code aléatoire (alphabet de Crockford : pas de I, L, O, U pour éviter les confusions)
create or replace function private.rand_code(n integer)
returns text
language plpgsql volatile
set search_path = ''
as $$
declare
  abc constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  r text := '';
begin
  for i in 1..n loop
    r := r || substr(abc, (get_byte(uuid_send(gen_random_uuid()), 0) % 32) + 1, 1);
  end loop;
  return r;
end
$$;

-- Ce qu'une personne tape : minuscules, tirets, O à la place de 0…
create or replace function private.norm_code(p text)
returns text
language sql immutable
set search_path = ''
as $$
  select translate(upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')), 'OILU', '011V')
$$;

create or replace function private.try_date(p text)
returns date
language plpgsql immutable
set search_path = ''
as $$
begin
  if p is null or p !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return p::date;
exception when others then
  return null;
end
$$;

create or replace function private.try_int(p text, lo integer, hi integer)
returns integer
language sql immutable
set search_path = ''
as $$
  select case when p ~ '^\d{1,9}$' then least(greatest(p::integer, lo), hi) else lo end
$$;

create or replace function private.venue_json(v public.venues, with_secret boolean)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'code', v.code, 'name', v.name, 'city', v.city, 'cat', v.cat, 'lat', v.lat, 'lng', v.lng,
    'createdAt', (extract(epoch from v.created_at) * 1000)::bigint,
    'secret', case when with_secret then v.secret end))
$$;

revoke all on all functions in schema private from public;

-- ---------------------------------------------------------------------
--  Fonctions appelées par l'app
-- ---------------------------------------------------------------------

-- Créer son compte et réserver son pseudo (définitif)
create or replace function public.register(p_key text, p_pseudo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id     uuid;
  v_pseudo text := btrim(regexp_replace(coalesce(p_pseudo, ''), '\s+', ' ', 'g'));
begin
  if coalesce(p_key, '') !~ '^[0-9A-HJKMNP-TV-Z]{16}$' then
    return jsonb_build_object('ok', false, 'error', 'key');
  end if;

  -- Même clé déjà enregistrée : la première demande avait abouti (réseau capricieux)
  v_id := private.account_of(p_key);
  if v_id is not null then
    return (select jsonb_build_object('ok', true, 'id', v_id, 'pseudo', p.pseudo, 'rev', g.rev)
            from public.players p join public.progress g on g.id = p.id where p.id = v_id);
  end if;

  if char_length(v_pseudo) < 2 or char_length(v_pseudo) > 20 then
    return jsonb_build_object('ok', false, 'error', 'length');
  end if;
  if v_pseudo !~ '^[A-Za-z0-9À-ÖØ-öø-ÿĀ-ž][A-Za-z0-9À-ÖØ-öø-ÿĀ-ž _.''-]*$' then
    return jsonb_build_object('ok', false, 'error', 'chars');
  end if;
  if lower(v_pseudo) in ('admin', 'administrateur', 'dehors', 'equipe dehors', 'équipe dehors',
                         'moderateur', 'modérateur', 'staff', 'support', 'officiel') then
    return jsonb_build_object('ok', false, 'error', 'taken');
  end if;
  if exists (select 1 from public.players p where lower(p.pseudo) = lower(v_pseudo)) then
    return jsonb_build_object('ok', false, 'error', 'taken');
  end if;

  insert into public.accounts (key_hash) values (sha256(convert_to(p_key, 'UTF8'))) returning id into v_id;
  insert into public.players (id, pseudo) values (v_id, v_pseudo);
  insert into public.progress (id) values (v_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'pseudo', v_pseudo, 'rev', 0);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'taken');
end
$$;

-- Ouvrir son compte : pseudo, droits, et la progression si elle a changé ailleurs
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

  select jsonb_build_object(
           'id', p.id,
           'pseudo', p.pseudo,
           'rev', g.rev,
           'admin', private.is_admin(v_id))
         || case when p_rev is distinct from g.rev then jsonb_build_object('state', g.state) else '{}'::jsonb end
    into r
  from public.players p
  join public.progress g on g.id = p.id
  where p.id = v_id;
  return r;
end
$$;

-- Enregistrer : profil public et/ou progression.
-- La progression n'est écrite que si p_rev correspond à la version en base ;
-- sinon on renvoie la version en base pour que l'app fusionne, puis réessaie.
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
                     and octet_length((p_player -> 'showcase')::text) <= 1500
                    then jsonb_path_query_array(p_player -> 'showcase', '$[0 to 2]')
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

-- Sa place au classement, quand on n'est pas dans le haut du tableau
create or replace function public.board_position(p_points integer)
returns jsonb
language sql stable
set search_path = ''
as $$
  select jsonb_build_object(
    'pos',   (select count(*) + 1 from public.players p where p.points > coalesce(p_points, 0)),
    'total', (select count(*) from public.players))
$$;

-- Supprimer son compte et toutes ses données
create or replace function public.delete_account(p_key text)
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
  delete from public.accounts where id = v_id;
  return jsonb_build_object('ok', true);
end
$$;

-- Scanner un QR code ou taper le code d'un lieu partenaire
create or replace function public.venue_find(p_secret text)
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select private.venue_json(v, false)
  from public.venues v
  where v.secret = private.norm_code(p_secret)
$$;

-- Espace établissements (administrateurs seulement)
create or replace function public.venue_admin_list(p_key text)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_id uuid := private.account_of(p_key);
begin
  if not private.is_admin(v_id) then
    return null;
  end if;
  return coalesce((select jsonb_agg(private.venue_json(v, true) order by v.created_at desc)
                   from public.venues v), '[]'::jsonb);
end
$$;

create or replace function public.venue_add(p_key text, p_venue jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id     uuid := private.account_of(p_key);
  v_secret text;
  v_row    public.venues;
begin
  if not private.is_admin(v_id) then
    return jsonb_build_object('ok', false, 'error', 'admin');
  end if;
  loop
    v_secret := private.rand_code(8);
    exit when not exists (select 1 from public.venues v where v.secret = v_secret);
  end loop;
  insert into public.venues (code, secret, name, city, cat, lat, lng, created_by)
  values (
    p_venue ->> 'code',
    v_secret,
    btrim(p_venue ->> 'name'),
    btrim(coalesce(p_venue ->> 'city', '')),
    p_venue ->> 'cat',
    case when jsonb_typeof(p_venue -> 'lat') = 'number' then (p_venue ->> 'lat')::double precision end,
    case when jsonb_typeof(p_venue -> 'lng') = 'number' then (p_venue ->> 'lng')::double precision end,
    v_id)
  returning * into v_row;
  return jsonb_build_object('ok', true, 'venue', private.venue_json(v_row, true));
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'exists');
  when check_violation or not_null_violation then
    return jsonb_build_object('ok', false, 'error', 'invalid');
end
$$;

create or replace function public.venue_delete(p_key text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := private.account_of(p_key);
begin
  if not private.is_admin(v_id) then
    return jsonb_build_object('ok', false, 'error', 'admin');
  end if;
  delete from public.venues where code = p_code;
  return jsonb_build_object('ok', true);
end
$$;

-- Seules ces fonctions sont appelables depuis l'app
revoke all on function
  public.register(text, text),
  public.me(text, integer),
  public.save(text, jsonb, jsonb, integer),
  public.board_position(integer),
  public.delete_account(text),
  public.venue_find(text),
  public.venue_admin_list(text),
  public.venue_add(text, jsonb),
  public.venue_delete(text, text)
  from public;
grant execute on function
  public.register(text, text),
  public.me(text, integer),
  public.save(text, jsonb, jsonb, integer),
  public.board_position(integer),
  public.delete_account(text),
  public.venue_find(text),
  public.venue_admin_list(text),
  public.venue_add(text, jsonb),
  public.venue_delete(text, text)
  to anon, authenticated;
