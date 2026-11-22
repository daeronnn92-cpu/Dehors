-- =====================================================================
--  Dehors : comptes reliés à Google ou à une adresse e-mail
-- =====================================================================
--  - Un compte peut vivre sur plusieurs appareils : chaque appareil garde
--    sa propre clé secrète (table account_keys, empreintes uniquement).
--  - Un compte peut être relié à un utilisateur Supabase Auth (Google ou
--    code reçu par e-mail) pour être retrouvé sur n'importe quel appareil.
--  - La session Supabase Auth ne sert qu'au moment de relier ou de se
--    connecter : ensuite, l'appareil continue avec sa clé.
-- =====================================================================

-- Une clé par appareil
create table public.account_keys (
  key_hash   bytea primary key,
  account_id uuid not null references public.accounts (id) on delete cascade,
  created_at timestamptz not null default now()
);
create index account_keys_account_idx on public.account_keys (account_id);
alter table public.account_keys enable row level security;
revoke all on public.account_keys from anon, authenticated;

insert into public.account_keys (key_hash, account_id, created_at)
select key_hash, id, created_at from public.accounts;

alter table public.accounts drop column key_hash;

-- Le lien avec Google ou l'adresse e-mail
alter table public.accounts
  add column auth_id       uuid unique references auth.users (id) on delete set null,
  add column auth_email    text,
  add column auth_provider text;

-- ---------------------------------------------------------------------
--  Fonctions mises à jour
-- ---------------------------------------------------------------------
create or replace function private.account_of(p_key text)
returns uuid
language sql stable
set search_path = ''
as $$
  select k.account_id
  from public.account_keys k
  where coalesce(p_key, '') ~ '^[0-9A-HJKMNP-TV-Z]{16}$'
    and k.key_hash = sha256(convert_to(p_key, 'UTF8'))
$$;

-- Identité Supabase Auth de la requête (null si absente ou anonyme)
create or replace function private.auth_user()
returns uuid
language sql stable
set search_path = ''
as $$
  select case
    when coalesce(auth.jwt() ->> 'role', '') = 'authenticated'
     and not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
    then auth.uid() end
$$;
revoke all on function private.auth_user() from public;

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

  insert into public.accounts default values returning id into v_id;
  insert into public.account_keys (key_hash, account_id) values (sha256(convert_to(p_key, 'UTF8')), v_id);
  insert into public.players (id, pseudo) values (v_id, v_pseudo);
  insert into public.progress (id) values (v_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'pseudo', v_pseudo, 'rev', 0);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'taken');
end
$$;

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
           'admin', private.is_admin(v_id),
           'email', a.auth_email,
           'provider', a.auth_provider)
         || case when p_rev is distinct from g.rev then jsonb_build_object('state', g.state) else '{}'::jsonb end
    into r
  from public.players p
  join public.progress g on g.id = p.id
  join public.accounts a on a.id = p.id
  where p.id = v_id;
  return r;
end
$$;

-- Supprimer son compte : profil, progression, appareils, et l'adresse reliée
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
  select a.auth_id into v_auth from public.accounts a where a.id = v_id;
  delete from public.accounts where id = v_id;
  if v_auth is not null then
    begin
      delete from auth.users where id = v_auth;
    exception when others then
      null;  -- l'adresse sera retirée à la main si besoin ; le compte Dehors, lui, est bien supprimé
    end;
  end if;
  return jsonb_build_object('ok', true);
end
$$;

-- ---------------------------------------------------------------------
--  Nouvelles fonctions
-- ---------------------------------------------------------------------

-- Relier son compte à Google ou à son e-mail (appelée avec la session Supabase Auth)
create or replace function public.link_account(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid := private.account_of(p_key);
  v_uid   uuid := private.auth_user();
  v_mail  text := lower(auth.jwt() ->> 'email');
  v_prov  text := coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', 'email');
  v_other uuid;
  v_cur   uuid;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'key');
  end if;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;
  select a.id into v_other from public.accounts a where a.auth_id = v_uid;
  if v_other = v_id then
    return jsonb_build_object('ok', true, 'email', v_mail, 'provider', v_prov);
  end if;
  if v_other is not null then
    return jsonb_build_object('ok', false, 'error', 'other',
                              'pseudo', (select p.pseudo from public.players p where p.id = v_other));
  end if;
  select a.auth_id into v_cur from public.accounts a where a.id = v_id;
  if v_cur is not null then
    return jsonb_build_object('ok', false, 'error', 'already',
                              'email', (select a.auth_email from public.accounts a where a.id = v_id));
  end if;
  update public.accounts set auth_id = v_uid, auth_email = v_mail, auth_provider = v_prov where id = v_id;
  return jsonb_build_object('ok', true, 'email', v_mail, 'provider', v_prov);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'other');
end
$$;

-- Se connecter sur un nouvel appareil : il reçoit sa propre clé
create or replace function public.login_device(p_new_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := private.auth_user();
  v_id   uuid;
  v_hash bytea;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'auth');
  end if;
  if coalesce(p_new_key, '') !~ '^[0-9A-HJKMNP-TV-Z]{16}$' then
    return jsonb_build_object('ok', false, 'error', 'key');
  end if;
  select a.id into v_id from public.accounts a where a.auth_id = v_uid;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'none');
  end if;
  v_hash := sha256(convert_to(p_new_key, 'UTF8'));
  insert into public.account_keys (key_hash, account_id) values (v_hash, v_id)
  on conflict (key_hash) do nothing;
  if not exists (select 1 from public.account_keys k where k.key_hash = v_hash and k.account_id = v_id) then
    return jsonb_build_object('ok', false, 'error', 'key');
  end if;
  -- 20 appareils au plus : les plus anciens sont oubliés
  delete from public.account_keys k
  where k.account_id = v_id
    and k.key_hash in (select k2.key_hash from public.account_keys k2
                       where k2.account_id = v_id order by k2.created_at desc offset 20);
  return public.me(p_new_key) || jsonb_build_object('ok', true);
end
$$;

-- Se déconnecter de cet appareil (seulement si le compte est relié : on pourra revenir)
create or replace function public.logout_device(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := private.account_of(p_key);
begin
  if v_id is null then
    return jsonb_build_object('ok', true);
  end if;
  if not exists (select 1 from public.accounts a where a.id = v_id and a.auth_id is not null) then
    return jsonb_build_object('ok', false, 'error', 'unlinked');
  end if;
  delete from public.account_keys where key_hash = sha256(convert_to(p_key, 'UTF8'));
  return jsonb_build_object('ok', true);
end
$$;

revoke all on function
  public.link_account(text),
  public.login_device(text),
  public.logout_device(text)
  from public;
grant execute on function
  public.link_account(text),
  public.login_device(text),
  public.logout_device(text)
  to anon, authenticated;
