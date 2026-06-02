-- ORIN PRODUCTION SUPABASE SCHEMA
-- Idempotent.  Run as a single file in the Supabase SQL Editor.
-- Ordering: extensions -> enums -> pure helpers -> tables -> table-dep helpers -> triggers -> RLS -> storage -> grants -> realtime -> seed.

-- 0. EXTENSIONS
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";
create extension if not exists "citext";
create extension if not exists "pg_trgm";

-- 1. ENUM TYPES
do $$ begin create type public.user_role as enum ('user','admin','moderator');
exception when duplicate_object then null; end $$;
do $$ begin create type public.account_status as enum ('active','pending','suspended','deactivated');
exception when duplicate_object then null; end $$;
do $$ begin create type public.student_year as enum ('first','second','third','fourth','graduate');
exception when duplicate_object then null; end $$;
do $$ begin create type public.proof_source_type as enum
  ('github','kaggle','certificate','hackathon','project','blog','demo','other');
exception when duplicate_object then null; end $$;
do $$ begin create type public.verification_status as enum ('draft','pending','verified','rejected');
exception when duplicate_object then null; end $$;
do $$ begin create type public.visibility_status as enum ('private','unlisted','public');
exception when duplicate_object then null; end $$;
do $$ begin create type public.opportunity_type as enum
  ('internship','job','scholarship','mentorship','hackathon','research','other');
exception when duplicate_object then null; end $$;
do $$ begin create type public.coach_note_type as enum ('daily','weekly','milestone','ad_hoc');
exception when duplicate_object then null; end $$;
do $$ begin create type public.integration_status as enum ('connected','disconnected','pending','error');
exception when duplicate_object then null; end $$;
do $$ begin create type public.auth_provider as enum ('email','google','github','apple','linkedin');
exception when duplicate_object then null; end $$;
do $$ begin create type public.contact_status as enum ('new','in_progress','resolved','spam');
exception when duplicate_object then null; end $$;
do $$ begin create type public.notification_type as enum
  ('recruiter_view','verification_update','opportunity_match','coach_tip','weekly_summary','system');
exception when duplicate_object then null; end $$;
do $$ begin create type public.share_token_kind as enum ('link','email','recruiter_invite');
exception when duplicate_object then null; end $$;
do $$ begin create type public.subscription_plan as enum ('free','pro','team');
exception when duplicate_object then null; end $$;
do $$ begin create type public.subscription_status as enum ('active','canceled','past_due','trialing','incomplete');
exception when duplicate_object then null; end $$;

-- 2. PURE HELPER FUNCTIONS  (no table references)
create or replace function public.fn_set_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create or replace function public.fn_slugify_username(p_input text)
returns text language plpgsql immutable as $$
declare v text;
begin
  v := lower(coalesce(p_input,''));
  v := regexp_replace(v, '[^a-z0-9_-]+', '-', 'g');
  v := regexp_replace(v, '-+', '-', 'g');
  v := trim(both '-' from v);
  return left(v, 30);
end $$;
-- 3. CORE TABLES

-- 3.1 USERS (1:1 with auth.users) -- must exist before any function references it
create table if not exists public.users (
  id                  uuid          primary key default gen_random_uuid(),
  auth_user_id        uuid          unique references auth.users(id) on delete cascade,
  email               citext        not null unique,
  username            citext        not null unique,
  full_name           text,
  avatar_url          text,
  college             text,
  year                public.student_year,
  bio                 text          check (bio is null or char_length(bio) <= 500),
  headline            text,
  location            text,
  website_url         text,
  github_url          text,
  linkedin_url        text,
  twitter_url         text,
  role                public.user_role     not null default 'user',
  account_status      public.account_status not null default 'active',
  is_profile_public   boolean               not null default true,
  hide_email          boolean               not null default false,
  email_verified      boolean               not null default false,
  auth_provider       public.auth_provider  not null default 'email',
  last_login_at       timestamptz,
  registration_ip     inet,
  registration_ua     text,
  created_at          timestamptz   not null default now(),
  updated_at          timestamptz   not null default now(),
  deleted_at          timestamptz,
  constraint users_username_length check (char_length(username) between 3 and 30),
  constraint users_username_format check (username ~ '^[a-z0-9_-]+$'),
  constraint users_full_name_length check (full_name is null or char_length(full_name) <= 100),
  constraint users_email_format    check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);
create index if not exists idx_users_auth_user_id   on public.users (auth_user_id);
create index if not exists idx_users_username      on public.users (username);
create index if not exists idx_users_email          on public.users (email);
create index if not exists idx_users_full_name_trgm on public.users using gin (full_name gin_trgm_ops);
create index if not exists idx_users_college_trgm   on public.users using gin (college gin_trgm_ops);
create index if not exists idx_users_role           on public.users (role);
create index if not exists idx_users_status         on public.users (account_status);
create index if not exists idx_users_created_at     on public.users (created_at desc);
create index if not exists idx_users_active         on public.users (id) where deleted_at is null;
create index if not exists idx_users_public         on public.users (username) where is_profile_public = true and deleted_at is null;
create trigger trg_users_set_updated_at before update on public.users
  for each row execute function public.fn_set_updated_at();

-- 3.2 PROOF CARDS
create table if not exists public.proof_cards (
  id                   uuid          primary key default gen_random_uuid(),
  user_id              uuid          not null references public.users(id) on delete cascade,
  title                text          not null check (char_length(title) between 1 and 200),
  description          text          check (description is null or char_length(description) <= 2000),
  source_type          public.proof_source_type   not null,
  source_url           text,
  thumbnail_url        text,
  skills_extracted     text[]        not null default '{}',
  skills_user_added    text[]        not null default '{}',
  what_it_proves       text[]        not null default '{}',
  verification_status  public.verification_status not null default 'pending',
  visibility           public.visibility_status   not null default 'private',
  verified_at          timestamptz,
  view_count           integer       not null default 0 check (view_count >= 0),
  is_highlighted       boolean       not null default false,
  sort_order           integer       not null default 0,
  metadata             jsonb         not null default '{}'::jsonb,
  created_at           timestamptz   not null default now(),
  updated_at           timestamptz   not null default now(),
  deleted_at           timestamptz
);
create index if not exists idx_proof_cards_user_id          on public.proof_cards (user_id);
create index if not exists idx_proof_cards_status           on public.proof_cards (verification_status);
create index if not exists idx_proof_cards_visibility       on public.proof_cards (visibility);
create index if not exists idx_proof_cards_user_status      on public.proof_cards (user_id, verification_status);
create index if not exists idx_proof_cards_user_created     on public.proof_cards (user_id, created_at desc);
create index if not exists idx_proof_cards_user_updated     on public.proof_cards (user_id, updated_at desc);
create index if not exists idx_proof_cards_skills_gin       on public.proof_cards using gin (skills_extracted);
create index if not exists idx_proof_cards_user_added_gin   on public.proof_cards using gin (skills_user_added);
create index if not exists idx_proof_cards_title_trgm       on public.proof_cards using gin (title gin_trgm_ops);
create index if not exists idx_proof_cards_source_type      on public.proof_cards (source_type);
create index if not exists idx_proof_cards_active           on public.proof_cards (user_id) where deleted_at is null;
create index if not exists idx_proof_cards_public_verified  on public.proof_cards (user_id) where visibility = 'public' and verification_status = 'verified' and deleted_at is null;

-- 3.3 PROOF SOURCES
create table if not exists public.proof_sources (
  id              uuid          primary key default gen_random_uuid(),
  user_id         uuid          not null references public.users(id) on delete cascade,
  source_type     public.proof_source_type not null,
  source_url      text,
  source_name     text,
  is_connected    boolean       not null default true,
  last_synced_at  timestamptz,
  metadata        jsonb         not null default '{}'::jsonb,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now(),
  deleted_at      timestamptz,
  constraint proof_sources_url_or_name check (source_url is not null or source_name is not null)
);
create index if not exists idx_proof_sources_user_id   on public.proof_sources (user_id);
create index if not exists idx_proof_sources_user_type on public.proof_sources (user_id, source_type);
create index if not exists idx_proof_sources_active    on public.proof_sources (user_id) where deleted_at is null;
create trigger trg_proof_sources_set_updated_at before update on public.proof_sources
  for each row execute function public.fn_set_updated_at();

-- 3.4 PROOF SHARES
create table if not exists public.proof_shares (
  id              uuid          primary key default gen_random_uuid(),
  proof_id        uuid          not null references public.proof_cards(id) on delete cascade,
  owner_id        uuid          not null references public.users(id) on delete cascade,
  recipient_email citext        not null,
  recipient_name  text,
  token           text          unique,
  kind            public.share_token_kind not null default 'recruiter_invite',
  message         text,
  expires_at      timestamptz,
  last_viewed_at  timestamptz,
  view_count      integer       not null default 0 check (view_count >= 0),
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now(),
  deleted_at      timestamptz
);
create unique index if not exists idx_proof_shares_proof_email
  on public.proof_shares (proof_id, recipient_email) where deleted_at is null;
create index if not exists idx_proof_shares_owner      on public.proof_shares (owner_id);
create index if not exists idx_proof_shares_email      on public.proof_shares (recipient_email);
create index if not exists idx_proof_shares_token      on public.proof_shares (token);
create trigger trg_proof_shares_set_updated_at before update on public.proof_shares
  for each row execute function public.fn_set_updated_at();

-- 3.5 PROOF VIEWS
create table if not exists public.proof_views (
  id             uuid          primary key default gen_random_uuid(),
  proof_id       uuid          not null references public.proof_cards(id) on delete cascade,
  owner_id       uuid          not null references public.users(id) on delete cascade,
  viewer_user_id uuid          references public.users(id) on delete set null,
  ip_address     inet,
  user_agent     text,
  referer        text,
  viewed_at      timestamptz   not null default now()
);
create index if not exists idx_proof_views_proof_id  on public.proof_views (proof_id, viewed_at desc);
create index if not exists idx_proof_views_owner     on public.proof_views (owner_id, viewed_at desc);
create index if not exists idx_proof_views_viewer    on public.proof_views (viewer_user_id);
create index if not exists idx_proof_views_daily     on public.proof_views (proof_id, viewed_at);
-- 3.6 OPPORTUNITIES
create table if not exists public.opportunities (
  id                 uuid            primary key default gen_random_uuid(),
  title              text            not null check (char_length(title) between 1 and 200),
  company            text            not null check (char_length(company) between 1 and 200),
  type               public.opportunity_type not null default 'internship',
  required_skills    text[]          not null default '{}',
  nice_to_have       text[]          not null default '{}',
  description        text,
  location           text,
  is_remote          boolean         not null default false,
  link               text            not null,
  apply_deadline     timestamptz,
  match_percentage   numeric(5,2)    not null default 0 check (match_percentage between 0 and 100),
  salary_min         numeric(12,2),
  salary_max         numeric(12,2),
  salary_currency    text            default 'USD',
  source             text,
  source_external_id text            unique,
  is_active          boolean         not null default true,
  posted_at          timestamptz,
  metadata           jsonb           not null default '{}'::jsonb,
  created_at         timestamptz     not null default now(),
  updated_at         timestamptz     not null default now(),
  deleted_at         timestamptz
);
create index if not exists idx_opportunities_company          on public.opportunities using gin (company gin_trgm_ops);
create index if not exists idx_opportunities_title           on public.opportunities using gin (title gin_trgm_ops);
create index if not exists idx_opportunities_type            on public.opportunities (type);
create index if not exists idx_opportunities_required_skills on public.opportunities using gin (required_skills);
create index if not exists idx_opportunities_active          on public.opportunities (is_active, apply_deadline);
create index if not exists idx_opportunities_created_at      on public.opportunities (created_at desc);
create index if not exists idx_opportunities_match           on public.opportunities (match_percentage desc);
create trigger trg_opportunities_set_updated_at before update on public.opportunities
  for each row execute function public.fn_set_updated_at();

-- 3.7 USER <-> OPPORTUNITY
create table if not exists public.user_opportunities (
  id              uuid          primary key default gen_random_uuid(),
  user_id         uuid          not null references public.users(id) on delete cascade,
  opportunity_id  uuid          not null references public.opportunities(id) on delete cascade,
  status          text          not null default 'saved' check (status in ('saved','applied','dismissed','interviewing','rejected','offered')),
  match_score     numeric(5,2)  check (match_score is null or match_score between 0 and 100),
  notes           text,
  applied_at      timestamptz,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now(),
  constraint uq_user_opp unique (user_id, opportunity_id)
);
create index if not exists idx_user_opp_user   on public.user_opportunities (user_id, status);
create index if not exists idx_user_opp_status on public.user_opportunities (status);
create trigger trg_user_opp_set_updated_at before update on public.user_opportunities
  for each row execute function public.fn_set_updated_at();

-- 3.8 COACH NOTES
create table if not exists public.coach_notes (
  id          uuid            primary key default gen_random_uuid(),
  user_id     uuid            not null references public.users(id) on delete cascade,
  type        public.coach_note_type not null default 'ad_hoc',
  content     text            not null check (char_length(content) between 1 and 4000),
  action_label text,
  action_url   text,
  priority    smallint        not null default 0,
  expires_at  timestamptz,
  created_at  timestamptz     not null default now(),
  updated_at  timestamptz     not null default now(),
  deleted_at  timestamptz
);
create index if not exists idx_coach_notes_user_id     on public.coach_notes (user_id);
create index if not exists idx_coach_notes_user_active on public.coach_notes (user_id, created_at desc) where deleted_at is null;
create index if not exists idx_coach_notes_user_type   on public.coach_notes (user_id, type);
create trigger trg_coach_notes_set_updated_at before update on public.coach_notes
  for each row execute function public.fn_set_updated_at();

-- 3.9 CONTACT MESSAGES
create table if not exists public.contact_messages (
  id           uuid              primary key default gen_random_uuid(),
  name         text              not null check (char_length(name) between 1 and 100),
  email        citext            not null,
  subject      text,
  message      text              not null check (char_length(message) between 10 and 2000),
  status       public.contact_status not null default 'new',
  user_id      uuid              references public.users(id) on delete set null,
  ip_address   inet,
  user_agent   text,
  assigned_to  uuid              references public.users(id) on delete set null,
  resolved_at  timestamptz,
  created_at   timestamptz       not null default now(),
  updated_at   timestamptz       not null default now(),
  deleted_at   timestamptz
);
create index if not exists idx_contact_status     on public.contact_messages (status);
create index if not exists idx_contact_email      on public.contact_messages (email);
create index if not exists idx_contact_created_at on public.contact_messages (created_at desc);
create trigger trg_contact_set_updated_at before update on public.contact_messages
  for each row execute function public.fn_set_updated_at();

-- 3.10 NOTIFICATIONS
create table if not exists public.notifications (
  id            uuid                 primary key default gen_random_uuid(),
  user_id       uuid                 not null references public.users(id) on delete cascade,
  type          public.notification_type not null,
  title         text                 not null,
  body          text,
  link          text,
  payload       jsonb                not null default '{}'::jsonb,
  read_at       timestamptz,
  created_at    timestamptz          not null default now(),
  updated_at    timestamptz          not null default now(),
  deleted_at    timestamptz
);
create index if not exists idx_notifications_user_id     on public.notifications (user_id, created_at desc);
create index if not exists idx_notifications_user_unread on public.notifications (user_id) where read_at is null and deleted_at is null;
create index if not exists idx_notifications_type        on public.notifications (type);
create trigger trg_notifications_set_updated_at before update on public.notifications
  for each row execute function public.fn_set_updated_at();

-- 3.11 NOTIFICATION PREFERENCES
create table if not exists public.notification_preferences (
  user_id              uuid   primary key references public.users(id) on delete cascade,
  weekly_summary       boolean not null default true,
  recruiter_views      boolean not null default true,
  verification_status  boolean not null default false,
  opportunity_match    boolean not null default true,
  coach_tips           boolean not null default false,
  product_updates      boolean not null default true,
  updated_at           timestamptz not null default now(),
  created_at           timestamptz not null default now()
);
create trigger trg_notif_prefs_set_updated_at before update on public.notification_preferences
  for each row execute function public.fn_set_updated_at();

-- 3.12 USER INTEGRATIONS
create table if not exists public.user_integrations (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users(id) on delete cascade,
  provider        public.auth_provider not null,
  external_user_id text,
  external_username text,
  access_token    text,
  refresh_token   text,
  token_expires_at timestamptz,
  scopes          text[] not null default '{}',
  status          public.integration_status not null default 'pending',
  last_synced_at  timestamptz,
  metadata        jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz,
  constraint uq_user_provider unique (user_id, provider)
);
create index if not exists idx_user_integrations_user   on public.user_integrations (user_id);
create index if not exists idx_user_integrations_status on public.user_integrations (status);
create trigger trg_user_integrations_set_updated_at before update on public.user_integrations
  for each row execute function public.fn_set_updated_at();

-- 3.13 SUBSCRIPTIONS
create table if not exists public.subscriptions (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null unique references public.users(id) on delete cascade,
  plan                  public.subscription_plan not null default 'free',
  status                public.subscription_status not null default 'active',
  current_period_start  timestamptz,
  current_period_end    timestamptz,
  cancel_at_period_end  boolean not null default false,
  stripe_customer_id    text unique,
  stripe_subscription_id text unique,
  metadata              jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);
create index if not exists idx_subs_plan   on public.subscriptions (plan);
create index if not exists idx_subs_status on public.subscriptions (status);
create trigger trg_subs_set_updated_at before update on public.subscriptions
  for each row execute function public.fn_set_updated_at();

-- 3.14 AUDIT LOG
create table if not exists public.audit_log (
  id          uuid          primary key default gen_random_uuid(),
  actor_id    uuid          references public.users(id) on delete set null,
  actor_role  public.user_role,
  action      text          not null,
  entity_type text,
  entity_id   text,
  old_data    jsonb,
  new_data    jsonb,
  ip_address  inet,
  user_agent  text,
  created_at  timestamptz   not null default now()
);
create index if not exists idx_audit_actor      on public.audit_log (actor_id, created_at desc);
create index if not exists idx_audit_entity     on public.audit_log (entity_type, entity_id);
create index if not exists idx_audit_created_at on public.audit_log (created_at desc);
create index if not exists idx_audit_action     on public.audit_log (action);
-- 4. TABLE-DEPENDENT FUNCTIONS (now safe — all referenced tables exist)
--     These are defined AFTER the tables to avoid any PL/pgSQL parse-time checks.

-- 4.1 Resolve current public.users.id from auth.uid()
create or replace function public.fn_current_user_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.users where auth_user_id = auth.uid()
$$;

-- 4.2 Resolve current public.users.role
create or replace function public.fn_current_user_role()
returns public.user_role language sql stable security definer set search_path = public as $$
  select role from public.users where auth_user_id = auth.uid()
$$;

-- 4.3 True when the caller has admin / moderator role
create or replace function public.fn_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.users
    where auth_user_id = auth.uid() and role in ('admin','moderator')
  )
$$;

-- 4.4 Increment proof view counter
create or replace function public.fn_increment_proof_view(p_proof_id uuid)
returns void language sql security definer set search_path = public as $$
  update public.proof_cards
     set view_count = view_count + 1
   where id = p_proof_id and deleted_at is null;
$$;

-- 4.5 Auto-stamp verified_at on proof cards
create or replace function public.fn_proof_card_touch_timestamps()
returns trigger language plpgsql as $$
begin
  if new.verification_status = 'verified'
     and old.verification_status is distinct from 'verified' then
    new.verified_at := coalesce(new.verified_at, now());
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_proof_cards_set_updated_at on public.proof_cards;
create trigger trg_proof_cards_set_updated_at before update on public.proof_cards
  for each row execute function public.fn_proof_card_touch_timestamps();

-- 4.6 Auto-create a public.users row on auth.users INSERT (handles email + OAuth)
create or replace function public.fn_handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_full_name text; v_username text; v_base text;
begin
  v_full_name := coalesce(new.raw_user_meta_data->>'full_name','');
  v_base := case when v_full_name is not null and length(v_full_name) > 0
                 then v_full_name else split_part(new.email,'@',1) end;
  v_username := public.fn_slugify_username(v_base);
  if exists (select 1 from public.users where username = v_username) then
    v_username := v_username || '-' || substr(replace(new.id::text,'-',''),1,6);
  end if;
  insert into public.users (auth_user_id, email, username, full_name, avatar_url, role, account_status, auth_provider)
  values (new.id, new.email, v_username, nullif(v_full_name,''),
          new.raw_user_meta_data->>'avatar_url', 'user','active',
          coalesce(case when new.app_metadata->>'provider' = 'google' then 'google'::public.auth_provider
                        when new.app_metadata->>'provider' = 'github' then 'github'::public.auth_provider
                        else 'email'::public.auth_provider end,
                   'email'::public.auth_provider))
  on conflict (auth_user_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.fn_handle_new_auth_user();

-- 4.7 Track last_login_at
create or replace function public.fn_touch_last_login()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.last_sign_in_at is distinct from old.last_sign_in_at then
    update public.users set last_login_at = new.last_sign_in_at
    where auth_user_id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists trg_auth_user_login on auth.users;
create trigger trg_auth_user_login
  after update of last_sign_in_at on auth.users
  for each row execute function public.fn_touch_last_login();

-- 4.8 Auto-create a free subscription for every new user
create or replace function public.fn_create_default_subscription()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.subscriptions (user_id, plan, status)
  values (new.id, 'free', 'active')
  on conflict (user_id) do nothing;
  return new;
end $$;

drop trigger if exists trg_user_default_subscription on public.users;
create trigger trg_user_default_subscription
  after insert on public.users
  for each row execute function public.fn_create_default_subscription();
-- 5. ROW LEVEL SECURITY
alter table public.users                      enable row level security;
alter table public.proof_cards                enable row level security;
alter table public.proof_sources              enable row level security;
alter table public.proof_shares               enable row level security;
alter table public.proof_views                enable row level security;
alter table public.opportunities              enable row level security;
alter table public.user_opportunities         enable row level security;
alter table public.coach_notes                enable row level security;
alter table public.contact_messages           enable row level security;
alter table public.notifications              enable row level security;
alter table public.notification_preferences   enable row level security;
alter table public.user_integrations          enable row level security;
alter table public.subscriptions              enable row level security;
alter table public.audit_log                  enable row level security;

-- 5.1 USERS
drop policy if exists users_select_public on public.users;
drop policy if exists users_select_self   on public.users;
drop policy if exists users_insert_self   on public.users;
drop policy if exists users_update_self   on public.users;
drop policy if exists users_delete_self   on public.users;
drop policy if exists users_admin_all     on public.users;
create policy users_select_public on public.users for select using (
  deleted_at is null and is_profile_public = true and account_status = 'active');
create policy users_select_self on public.users for select using (auth_user_id = auth.uid());
create policy users_insert_self on public.users for insert with check (auth_user_id = auth.uid());
create policy users_update_self on public.users for update using (auth_user_id = auth.uid()) with check (auth_user_id = auth.uid());
create policy users_delete_self on public.users for delete using (auth_user_id = auth.uid());
create policy users_admin_all   on public.users for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.2 PROOF CARDS
drop policy if exists proof_cards_select_public  on public.proof_cards;
drop policy if exists proof_cards_select_owner    on public.proof_cards;
drop policy if exists proof_cards_insert_owner    on public.proof_cards;
drop policy if exists proof_cards_update_owner    on public.proof_cards;
drop policy if exists proof_cards_delete_owner    on public.proof_cards;
drop policy if exists proof_cards_admin_all       on public.proof_cards;
create policy proof_cards_select_public on public.proof_cards for select using (
  deleted_at is null and visibility = 'public' and verification_status = 'verified' and exists (
    select 1 from public.users u
    where u.id = proof_cards.user_id and u.deleted_at is null and u.is_profile_public = true and u.account_status = 'active'));
create policy proof_cards_select_owner on public.proof_cards for select using (user_id = public.fn_current_user_id());
create policy proof_cards_insert_owner on public.proof_cards for insert with check (user_id = public.fn_current_user_id());
create policy proof_cards_update_owner on public.proof_cards for update using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy proof_cards_delete_owner on public.proof_cards for delete using (user_id = public.fn_current_user_id());
create policy proof_cards_admin_all   on public.proof_cards for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.3 PROOF SOURCES
drop policy if exists proof_sources_select_owner  on public.proof_sources;
drop policy if exists proof_sources_insert_owner  on public.proof_sources;
drop policy if exists proof_sources_update_owner  on public.proof_sources;
drop policy if exists proof_sources_delete_owner  on public.proof_sources;
drop policy if exists proof_sources_admin_all     on public.proof_sources;
create policy proof_sources_select_owner on public.proof_sources for select using (user_id = public.fn_current_user_id());
create policy proof_sources_insert_owner on public.proof_sources for insert with check (user_id = public.fn_current_user_id());
create policy proof_sources_update_owner on public.proof_sources for update using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy proof_sources_delete_owner on public.proof_sources for delete using (user_id = public.fn_current_user_id());
create policy proof_sources_admin_all   on public.proof_sources for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.4 PROOF SHARES
drop policy if exists proof_shares_owner_all  on public.proof_shares;
drop policy if exists proof_shares_admin_all on public.proof_shares;
create policy proof_shares_owner_all on public.proof_shares for all using (owner_id = public.fn_current_user_id()) with check (owner_id = public.fn_current_user_id());
create policy proof_shares_admin_all on public.proof_shares for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.5 PROOF VIEWS
drop policy if exists proof_views_select_owner on public.proof_views;
drop policy if exists proof_views_insert_any   on public.proof_views;
drop policy if exists proof_views_admin_all    on public.proof_views;
create policy proof_views_select_owner on public.proof_views for select using (owner_id = public.fn_current_user_id());
create policy proof_views_insert_any   on public.proof_views for insert with check (true);
create policy proof_views_admin_all    on public.proof_views for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.6 OPPORTUNITIES
drop policy if exists opportunities_select_active on public.opportunities;
drop policy if exists opportunities_admin_all     on public.opportunities;
drop policy if exists opportunities_insert_admin  on public.opportunities;
create policy opportunities_select_active on public.opportunities for select using (is_active = true and deleted_at is null);
create policy opportunities_insert_admin  on public.opportunities for insert with check (public.fn_is_admin());
create policy opportunities_admin_all     on public.opportunities for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.7 USER OPPORTUNITIES
drop policy if exists user_opp_owner_all on public.user_opportunities;
drop policy if exists user_opp_admin_all on public.user_opportunities;
create policy user_opp_owner_all on public.user_opportunities for all using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy user_opp_admin_all on public.user_opportunities for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.8 COACH NOTES
drop policy if exists coach_notes_select_self on public.coach_notes;
drop policy if exists coach_notes_insert_self on public.coach_notes;
drop policy if exists coach_notes_update_self on public.coach_notes;
drop policy if exists coach_notes_delete_self on public.coach_notes;
drop policy if exists coach_notes_admin_all   on public.coach_notes;
create policy coach_notes_select_self on public.coach_notes for select using (user_id = public.fn_current_user_id());
create policy coach_notes_insert_self on public.coach_notes for insert with check (user_id = public.fn_current_user_id());
create policy coach_notes_update_self on public.coach_notes for update using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy coach_notes_delete_self on public.coach_notes for delete using (user_id = public.fn_current_user_id());
create policy coach_notes_admin_all   on public.coach_notes for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.9 CONTACT MESSAGES  (anon insert; admin read/update)
drop policy if exists contact_insert_anon  on public.contact_messages;
drop policy if exists contact_admin_all    on public.contact_messages;
create policy contact_insert_anon on public.contact_messages for insert with check (true);
create policy contact_admin_all   on public.contact_messages for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.10 NOTIFICATIONS
drop policy if exists notif_owner_all on public.notifications;
drop policy if exists notif_admin_all on public.notifications;
create policy notif_owner_all on public.notifications for all using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy notif_admin_all on public.notifications for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.11 NOTIFICATION PREFERENCES
drop policy if exists notif_prefs_owner_all on public.notification_preferences;
drop policy if exists notif_prefs_admin_all on public.notification_preferences;
create policy notif_prefs_owner_all on public.notification_preferences for all using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy notif_prefs_admin_all on public.notification_preferences for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.12 USER INTEGRATIONS
drop policy if exists user_integrations_owner_all on public.user_integrations;
drop policy if exists user_integrations_admin_all on public.user_integrations;
create policy user_integrations_owner_all on public.user_integrations for all using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy user_integrations_admin_all on public.user_integrations for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.13 SUBSCRIPTIONS
drop policy if exists subs_owner_select on public.subscriptions;
drop policy if exists subs_owner_insert on public.subscriptions;
drop policy if exists subs_owner_update on public.subscriptions;
drop policy if exists subs_admin_all    on public.subscriptions;
create policy subs_owner_select on public.subscriptions for select using (user_id = public.fn_current_user_id());
create policy subs_owner_insert on public.subscriptions for insert with check (user_id = public.fn_current_user_id());
create policy subs_owner_update on public.subscriptions for update using (user_id = public.fn_current_user_id()) with check (user_id = public.fn_current_user_id());
create policy subs_admin_all    on public.subscriptions for all using (public.fn_is_admin()) with check (public.fn_is_admin());

-- 5.14 AUDIT LOG  (admin only)
drop policy if exists audit_admin_read  on public.audit_log;
drop policy if exists audit_admin_write on public.audit_log;
create policy audit_admin_read  on public.audit_log for select using (public.fn_is_admin());
create policy audit_admin_write on public.audit_log for insert with check (public.fn_is_admin());
-- 6. STORAGE BUCKETS
insert into storage.buckets (id, name, public)
values
  ('avatars',     'avatars',     true),
  ('proof-files', 'proof-files', false),
  ('covers',      'covers',      true)
on conflict (id) do nothing;

drop policy if exists "avatars read"          on storage.objects;
drop policy if exists "avatars insert owner"  on storage.objects;
drop policy if exists "avatars update owner"  on storage.objects;
drop policy if exists "avatars delete owner"  on storage.objects;
create policy "avatars read"         on storage.objects for select using (bucket_id = 'avatars');
create policy "avatars insert owner" on storage.objects for insert with check (
  bucket_id = 'avatars' and auth.uid() is not null and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars update owner" on storage.objects for update using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars delete owner" on storage.objects for delete using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "proof-files read own"   on storage.objects;
drop policy if exists "proof-files insert own" on storage.objects;
drop policy if exists "proof-files update own" on storage.objects;
drop policy if exists "proof-files delete own" on storage.objects;
create policy "proof-files read own"   on storage.objects for select using (
  bucket_id = 'proof-files' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "proof-files insert own" on storage.objects for insert with check (
  bucket_id = 'proof-files' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "proof-files update own" on storage.objects for update using (
  bucket_id = 'proof-files' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "proof-files delete own" on storage.objects for delete using (
  bucket_id = 'proof-files' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "covers read"         on storage.objects;
drop policy if exists "covers insert owner" on storage.objects;
drop policy if exists "covers update owner" on storage.objects;
drop policy if exists "covers delete owner" on storage.objects;
create policy "covers read"         on storage.objects for select using (bucket_id = 'covers');
create policy "covers insert owner" on storage.objects for insert with check (
  bucket_id = 'covers' and auth.uid() is not null);
create policy "covers update owner" on storage.objects for update using (
  bucket_id = 'covers' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "covers delete owner" on storage.objects for delete using (
  bucket_id = 'covers' and (storage.foldername(name))[1] = auth.uid()::text);

-- 7. GRANTS
grant usage on schema public to anon, authenticated, service_role;
grant insert on public.contact_messages to anon;
grant select on storage.objects          to anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public grant usage, select on sequences to authenticated;
alter default privileges in schema public grant execute on functions to authenticated;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant all on functions to service_role;

-- 8. REALTIME
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='proof_cards') then
    execute 'alter publication supabase_realtime add table public.proof_cards';
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='opportunities') then
    execute 'alter publication supabase_realtime add table public.opportunities';
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='notifications') then
    execute 'alter publication supabase_realtime add table public.notifications';
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='coach_notes') then
    execute 'alter publication supabase_realtime add table public.coach_notes';
  end if;
end $$;

-- 9. SEED DATA  (idempotent)
insert into public.opportunities (id, title, company, type, required_skills, match_percentage, link, apply_deadline, is_active, posted_at)
values
  ('00000000-0000-0000-0000-000000000001'::uuid, 'Backend Engineering Intern',   'Amazon',   'internship',  array['Node.js','PostgreSQL'],  82, 'https://amazon.jobs/backend-intern',          now() + interval '45 days', true, now()),
  ('00000000-0000-0000-0000-000000000002'::uuid, 'Software Engineer - New Grad', 'Flipkart', 'job',         array['System Design','REST APIs'], 76, 'https://flipkart.careers/new-grad',         now() + interval '30 days', true, now()),
  ('00000000-0000-0000-0000-000000000003'::uuid, 'ML Research Apprenticeship',   'Google',   'mentorship',  array['Python','Transformers'],   69, 'https://careers.google.com/ml-apprenticeship', now() + interval '60 days', true, now()),
  ('00000000-0000-0000-0000-000000000004'::uuid, 'Open Source Grant',           'GitHub',   'scholarship', array['Open Source'],            55, 'https://github.com/sponsors/grants',         now() + interval '90 days', true, now())
on conflict (id) do update set
  title = excluded.title,
  company = excluded.company,
  type = excluded.type,
  required_skills = excluded.required_skills,
  match_percentage = excluded.match_percentage,
  link = excluded.link,
  apply_deadline = excluded.apply_deadline,
  is_active = excluded.is_active;

-- 10. DONE
-- Verify with:
--   select tablename, rowsecurity from pg_tables where schemaname = 'public' order by tablename;
--   select policyname, tablename from pg_policies where schemaname = 'public' order by tablename, policyname;
