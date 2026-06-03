-- =============================================================================
-- ORIN PRODUCTION SUPABASE SCHEMA  –  v2.0
-- =============================================================================
-- Idempotent.  Run in Supabase SQL Editor (single file, any number of times).
-- Ordering:
--   0. Extensions
--   1. Enums
--   2. Composite types (pure)
--   3. Pure helper functions
--   4. Core tables (with constraints, indexes, triggers)
--   5. Partitioned tables
--   6. Cleanup (old schema objects — safe once tables exist)
--   7. Table-dependent functions + triggers
--   8. Row-level security (policies)
--   9. Storage buckets + policies
--  10. Grants & default privileges
--  11. Realtime publication
--  12. Views
--  13. Materialized views + refresh
--  14. Seed data
--  15. Verification queries (comment-only)
-- =============================================================================

-- =============================================================================
-- 0. EXTENSIONS
-- =============================================================================
create extension if not exists "uuid-ossp"    with schema public;
create extension if not exists "pgcrypto"      with schema public;
create extension if not exists "citext"        with schema public;
create extension if not exists "pg_trgm"       with schema public;
create extension if not exists "pg_stat_statements" with schema public;

-- =============================================================================
-- 1. ENUM TYPES  (idempotent via exception block)
-- =============================================================================
do $$ begin
  create type public.user_role as enum ('user','admin','moderator');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.account_status as enum ('active','pending','suspended','deactivated');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.student_year as enum ('first','second','third','fourth','graduate');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.proof_source_type as enum
    ('github','kaggle','certificate','hackathon','project','blog','demo','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.verification_status as enum ('draft','pending','verified','rejected');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.visibility_status as enum ('private','unlisted','public');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.opportunity_type as enum
    ('internship','job','scholarship','mentorship','hackathon','research','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.coach_note_type as enum ('daily','weekly','milestone','ad_hoc');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.integration_status as enum ('connected','disconnected','pending','error');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.auth_provider as enum ('email','google','github','apple','linkedin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.contact_status as enum ('new','in_progress','resolved','spam');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_type as enum
    ('recruiter_view','verification_update','opportunity_match','coach_tip','weekly_summary','system');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.share_token_kind as enum ('link','email','recruiter_invite');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.subscription_plan as enum ('free','pro','team');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.subscription_status as enum
    ('active','canceled','past_due','trialing','incomplete');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.opportunity_status as enum
    ('saved','applied','dismissed','interviewing','rejected','offered');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.audit_action as enum
    ('create','update','delete','soft_delete','restore','login','export','admin_action');
exception when duplicate_object then null; end $$;

-- =============================================================================
-- 2. COMPOSITE TYPES
-- =============================================================================
create type public.proof_card_summary as (
  id              uuid,
  title           text,
  source_type     public.proof_source_type,
  verification_status public.verification_status,
  visibility      public.visibility_status,
  skills          text[],
  view_count      integer,
  created_at      timestamptz
);

-- =============================================================================
-- 3. PURE HELPER FUNCTIONS  (no table references)
-- =============================================================================

-- 3.1  Generic updated_at stamp
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- 3.2  Slugify text for username
create or replace function public.slugify_username(p_input text)
returns text
language plpgsql
immutable
as $$
declare
  v text;
begin
  v := lower(coalesce(p_input, ''));
  v := regexp_replace(v, '[^a-z0-9_-]+', '-', 'g');
  v := regexp_replace(v, '-+', '-', 'g');
  v := trim(both '-' from v);
  return left(v, 30);
end $$;

-- 3.3  Validate JSONB is an object (use in check constraints)
create or replace function public.jsonb_is_object(v JSONB)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(v) = 'object';
$$;

-- 3.4  Validate email format (centralised)
create or replace function public.is_valid_email(email citext)
returns boolean
language sql
immutable
as $$
  select email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$';
$$;

-- 3.5  Validate URL (basic)
create or replace function public.is_valid_url(url text)
returns boolean
language sql
immutable
as $$
  select url ~ '^https?://[^\s/$.?#].[^\s]*$';
$$;

-- =============================================================================
-- 4. CORE TABLES  (with constraints, indexes, triggers)
-- =============================================================================

-- 4.1 USERS (1:1 with auth.users)
create table if not exists public.users (
  id                  uuid                    primary key default gen_random_uuid(),
  auth_user_id        uuid                    unique references auth.users(id) on delete cascade,
  email               citext                  not null unique,
  username            citext                  not null unique,
  full_name           text,
  avatar_url          text,
  college             text,
  year                public.student_year,
  bio                 text,
  headline            text,
  location            text,
  website_url         text,
  github_url          text,
  linkedin_url        text,
  twitter_url         text,
  role                public.user_role            not null default 'user',
  account_status      public.account_status       not null default 'active',
  is_profile_public   boolean                     not null default true,
  hide_email          boolean                     not null default false,
  email_verified      boolean                     not null default false,
  auth_provider       public.auth_provider        not null default 'email',
  last_login_at       timestamptz,
  registration_ip     inet,
  registration_ua     text,
  onboarded           boolean                     not null default false,
  created_at          timestamptz                 not null default now(),
  updated_at          timestamptz                 not null default now(),
  deleted_at          timestamptz,

  -- Constraints
  constraint users_bio_length       check (bio is null or char_length(bio) <= 500),
  constraint users_username_length  check (char_length(username) between 3 and 30),
  constraint users_username_format  check (username ~ '^[a-z0-9_-]+$'),
  constraint users_full_name_length check (full_name is null or char_length(full_name) <= 100),
  constraint users_email_format     check (public.is_valid_email(email)),
  constraint users_url_website      check (website_url is null or public.is_valid_url(website_url)),
  constraint users_url_github       check (github_url  is null or public.is_valid_url(github_url)),
  constraint users_url_linkedin     check (linkedin_url is null or public.is_valid_url(linkedin_url)),
  constraint users_url_twitter      check (twitter_url  is null or public.is_valid_url(twitter_url))
);

comment on table  public.users is 'Platform user profiles (1:1 with auth.users)';
comment on column public.users.auth_user_id is 'FK to auth.users.id; nullable for invite-only flows';
comment on column public.users.onboarded    is 'Whether the user completed initial onboarding';

-- Indexes
create index if not exists idx_users_auth_user_id   on public.users (auth_user_id);
create index if not exists idx_users_username        on public.users (username);
create index if not exists idx_users_email           on public.users (email);
create index if not exists idx_users_full_name_trgm  on public.users using gin (full_name gin_trgm_ops);
create index if not exists idx_users_college_trgm    on public.users using gin (college gin_trgm_ops);
create index if not exists idx_users_role            on public.users (role);
create index if not exists idx_users_status          on public.users (account_status);
create index if not exists idx_users_created_at      on public.users (created_at desc);
create index if not exists idx_users_active_public   on public.users (username)
  where is_profile_public = true and account_status = 'active' and deleted_at is null;
create index if not exists idx_users_deleted_at      on public.users (deleted_at) where deleted_at is not null;

create trigger trg_users_set_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();


-- 4.2 PROOF CARDS (core entity — evidence items)
create table if not exists public.proof_cards (
  id                   uuid                         primary key default gen_random_uuid(),
  user_id              uuid                         not null references public.users(id) on delete cascade,
  title                text                         not null,
  description          text,
  source_type          public.proof_source_type     not null,
  source_url           text,
  thumbnail_url        text,
  skills_extracted     text[]                       not null default '{}',
  skills_user_added    text[]                       not null default '{}',
  what_it_proves       text[]                       not null default '{}',
  verification_status  public.verification_status   not null default 'pending',
  visibility           public.visibility_status      not null default 'private',
  verified_at          timestamptz,
  view_count           integer                      not null default 0,
  is_highlighted       boolean                      not null default false,
  sort_order           integer                      not null default 0,
  metadata             jsonb                        not null default '{}'::jsonb,
  created_at           timestamptz                  not null default now(),
  updated_at           timestamptz                  not null default now(),
  deleted_at           timestamptz,

  -- Constraints
  constraint proof_cards_title_length        check (char_length(title) between 1 and 200),
  constraint proof_cards_description_length  check (description is null or char_length(description) <= 2000),
  constraint proof_cards_view_count_nonneg   check (view_count >= 0),
  constraint proof_cards_metadata_is_object check (public.jsonb_is_object(metadata)),
  constraint proof_cards_source_url_valid    check (source_url is null or public.is_valid_url(source_url)),
  constraint proof_cards_thumbnail_url_valid check (thumbnail_url is null or public.is_valid_url(thumbnail_url)),
  constraint proof_cards_extracted_uniq      check ('' <> ALL(coalesce(skills_extracted, '{}'::text[]))),
  constraint proof_cards_user_added_uniq     check ('' <> ALL(coalesce(skills_user_added, '{}'::text[]))),
  constraint proof_cards_what_it_proves_uniq check ('' <> ALL(coalesce(what_it_proves, '{}'::text[])))
);

comment on table  public.proof_cards is 'Individual evidence cards linking a skill claim to a source artifact';
comment on column public.proof_cards.skills_extracted  is 'Skills auto-extracted from the linked source';
comment on column public.proof_cards.skills_user_added is 'Skills manually tagged by the user';
comment on column public.proof_cards.metadata          is 'Flexible JSONB for per-source-type fields (repo stars, Kaggle rank, etc.)';

-- Indexes
create index if not exists idx_proof_cards_user_id            on public.proof_cards (user_id);
create index if not exists idx_proof_cards_verification       on public.proof_cards (verification_status);
create index if not exists idx_proof_cards_visibility         on public.proof_cards (visibility);
create index if not exists idx_proof_cards_user_status        on public.proof_cards (user_id, verification_status);
create index if not exists idx_proof_cards_user_created       on public.proof_cards (user_id, created_at desc);
create index if not exists idx_proof_cards_user_updated       on public.proof_cards (user_id, updated_at desc);
create index if not exists idx_proof_cards_sort               on public.proof_cards (user_id, sort_order, created_at desc);
create index if not exists idx_proof_cards_skills_extracted   on public.proof_cards using gin (skills_extracted);
create index if not exists idx_proof_cards_skills_user_added  on public.proof_cards using gin (skills_user_added);
create index if not exists idx_proof_cards_title_trgm         on public.proof_cards using gin (title gin_trgm_ops);
create index if not exists idx_proof_cards_source_type        on public.proof_cards (source_type);
create index if not exists idx_proof_cards_active             on public.proof_cards (user_id) where deleted_at is null;
create index if not exists idx_proof_cards_public_verified    on public.proof_cards (user_id)
  where visibility = 'public' and verification_status = 'verified' and deleted_at is null;
create index if not exists idx_proof_cards_deleted_at         on public.proof_cards (deleted_at) where deleted_at is not null;

create trigger trg_proof_cards_set_updated_at
  before update on public.proof_cards
  for each row execute function public.set_updated_at();


-- 4.3 PROOF SOURCES (linked external accounts)
create table if not exists public.proof_sources (
  id              uuid                     primary key default gen_random_uuid(),
  user_id         uuid                     not null references public.users(id) on delete cascade,
  source_type     public.proof_source_type not null,
  source_url      text,
  source_name     text,
  is_connected    boolean                  not null default true,
  last_synced_at  timestamptz,
  metadata        jsonb                    not null default '{}'::jsonb,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now(),
  deleted_at      timestamptz,

  -- Constraints
  constraint proof_sources_url_or_name    check (source_url is not null or source_name is not null),
  constraint proof_sources_metadata_is_obj check (public.jsonb_is_object(metadata)),
  constraint proof_sources_url_valid      check (source_url is null or public.is_valid_url(source_url))
);

comment on table public.proof_sources is 'External OAuth accounts / URLs linked by the user as proof origins';

create index if not exists idx_proof_sources_user_id     on public.proof_sources (user_id);
create index if not exists idx_proof_sources_user_type   on public.proof_sources (user_id, source_type);
create index if not exists idx_proof_sources_active      on public.proof_sources (user_id) where deleted_at is null;
create index if not exists idx_proof_sources_connected   on public.proof_sources (user_id, is_connected) where deleted_at is null;

create trigger trg_proof_sources_set_updated_at
  before update on public.proof_sources
  for each row execute function public.set_updated_at();


-- 4.4 PROOF SHARES (track sharing of proofs to external recipients)
create table if not exists public.proof_shares (
  id              uuid                    primary key default gen_random_uuid(),
  proof_id        uuid                    not null references public.proof_cards(id) on delete cascade,
  owner_id        uuid                    not null references public.users(id) on delete cascade,
  recipient_email citext                  not null,
  recipient_name  text,
  token           text                    unique,
  kind            public.share_token_kind not null default 'recruiter_invite',
  message         text,
  expires_at      timestamptz,
  last_viewed_at  timestamptz,
  view_count      integer                 not null default 0,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now(),
  deleted_at      timestamptz,

  -- Constraints
  constraint proof_shares_view_count_nonneg check (view_count >= 0),
  constraint proof_shares_token_length      check (token is null or char_length(token) >= 8),
  constraint proof_shares_recipient_email   check (public.is_valid_email(recipient_email))
);

comment on table public.proof_shares is 'Tracked shares of proof cards to external viewers / recruiters';

create unique index if not exists idx_proof_shares_active_proof_email
  on public.proof_shares (proof_id, recipient_email) where deleted_at is null;
create index if not exists idx_proof_shares_owner      on public.proof_shares (owner_id);
create index if not exists idx_proof_shares_email      on public.proof_shares (recipient_email);
create index if not exists idx_proof_shares_token      on public.proof_shares (token) where token is not null;
create index if not exists idx_proof_shares_expires    on public.proof_shares (expires_at) where expires_at is not null;

create trigger trg_proof_shares_set_updated_at
  before update on public.proof_shares
  for each row execute function public.set_updated_at();


-- 4.5 PROOF_VIEWS  (master table; actual data in partitions, see §5)
create table if not exists public.proof_views (
  id             uuid          not null default gen_random_uuid(),
  proof_id       uuid          not null,
  owner_id       uuid          not null,
  viewer_user_id uuid,
  ip_address     inet,
  user_agent     text,
  referer        text,
  viewed_at      timestamptz   not null default now(),

  -- Partition key must be part of primary key
  primary key (id, viewed_at)
)
partition by range (viewed_at);

comment on table public.proof_views is 'Append-only analytics log of proof card / profile views (partitioned by month)';

create index if not exists idx_proof_views_proof_id on public.proof_views (proof_id, viewed_at desc);
create index if not exists idx_proof_views_owner    on public.proof_views (owner_id, viewed_at desc);
create index if not exists idx_proof_views_viewer   on public.proof_views (viewer_user_id);

-- We'll create partitions and FK-bearing clones in section 5.


-- 4.6 OPPORTUNITIES (listings: jobs, internships, scholarships, etc.)
create table if not exists public.opportunities (
  id                 uuid                     primary key default gen_random_uuid(),
  title              text                     not null,
  company            text                     not null,
  company_logo_url   text,
  type               public.opportunity_type  not null default 'internship',
  required_skills    text[]                   not null default '{}',
  nice_to_have       text[]                   not null default '{}',
  description        text,
  location           text,
  is_remote          boolean                  not null default false,
  link               text                     not null,
  apply_deadline     timestamptz,
  match_percentage   numeric(5,2)             not null default 0,
  salary_min         numeric(12,2),
  salary_max         numeric(12,2),
  salary_currency    text                     default 'USD',
  source             text,
  source_external_id text                     unique,
  is_active          boolean                  not null default true,
  posted_at          timestamptz,
  metadata           jsonb                    not null default '{}'::jsonb,
  created_at         timestamptz              not null default now(),
  updated_at         timestamptz              not null default now(),
  deleted_at         timestamptz,

  -- Constraints
  constraint opportunities_title_length        check (char_length(title) between 1 and 200),
  constraint opportunities_company_length      check (char_length(company) between 1 and 200),
  constraint opportunities_match_range         check (match_percentage between 0 and 100),
  constraint opportunities_salary_min_positive check (salary_min is null or salary_min >= 0),
  constraint opportunities_salary_max_positive check (salary_max is null or salary_max >= 0),
  constraint opportunities_salary_range        check (salary_min is null or salary_max is null or salary_min <= salary_max),
  constraint opportunities_metadata_is_object  check (public.jsonb_is_object(metadata)),
  constraint opportunities_link_valid          check (public.is_valid_url(link)),
  constraint opportunities_logo_valid          check (company_logo_url is null or public.is_valid_url(company_logo_url))
);

comment on table public.opportunities is 'Curated / imported job, internship, scholarship, and hackathon listings';

-- Indexes
create index if not exists idx_opportunities_company         on public.opportunities using gin (company gin_trgm_ops);
create index if not exists idx_opportunities_title           on public.opportunities using gin (title gin_trgm_ops);
create index if not exists idx_opportunities_type            on public.opportunities (type);
create index if not exists idx_opportunities_required_skills on public.opportunities using gin (required_skills);
create index if not exists idx_opportunities_nice_to_have    on public.opportunities using gin (nice_to_have);
create index if not exists idx_opportunities_active          on public.opportunities (is_active, apply_deadline);
create index if not exists idx_opportunities_created_at      on public.opportunities (created_at desc);
create index if not exists idx_opportunities_match           on public.opportunities (match_percentage desc);
create index if not exists idx_opportunities_remote          on public.opportunities (is_remote) where is_remote = true;
create index if not exists idx_opportunities_salary_range    on public.opportunities (salary_min, salary_max)
  where salary_min is not null;
create index if not exists idx_opportunities_deleted_at      on public.opportunities (deleted_at) where deleted_at is not null;

create trigger trg_opportunities_set_updated_at
  before update on public.opportunities
  for each row execute function public.set_updated_at();


-- 4.7 USER ↔ OPPORTUNITY (junction table)
create table if not exists public.user_opportunities (
  id              uuid                         primary key default gen_random_uuid(),
  user_id         uuid                         not null references public.users(id) on delete cascade,
  opportunity_id  uuid                         not null references public.opportunities(id) on delete cascade,
  status          public.opportunity_status    not null default 'saved',
  match_score     numeric(5,2),
  notes           text,
  applied_at      timestamptz,
  source          text                         default 'manual',
  created_at      timestamptz                  not null default now(),
  updated_at      timestamptz                  not null default now(),

  -- Constraints
  constraint user_opportunities_match_range check (match_score is null or match_score between 0 and 100),
  constraint user_opportunities_uq_pair    unique (user_id, opportunity_id),
  constraint user_opportunities_status_applied check (
    (status in ('applied','interviewing','rejected','offered') and applied_at is not null)
    or (status not in ('applied','interviewing','rejected','offered'))
  )
);

comment on table public.user_opportunities is 'Tracks each user interaction state with opportunities';

create index if not exists idx_user_opportunities_user     on public.user_opportunities (user_id, status);
create index if not exists idx_user_opportunities_status   on public.user_opportunities (status);
create index if not exists idx_user_opportunities_opp      on public.user_opportunities (opportunity_id);
create index if not exists idx_user_opportunities_applied  on public.user_opportunities (applied_at)
  where applied_at is not null;

create trigger trg_user_opportunities_set_updated_at
  before update on public.user_opportunities
  for each row execute function public.set_updated_at();


-- 4.8 COACH NOTES (AI-generated coaching / tip messages)
create table if not exists public.coach_notes (
  id           uuid                        primary key default gen_random_uuid(),
  user_id      uuid                        not null references public.users(id) on delete cascade,
  type         public.coach_note_type      not null default 'ad_hoc',
  content      text                        not null,
  action_label text,
  action_url   text,
  priority     smallint                    not null default 0,
  expires_at   timestamptz,
  created_at   timestamptz                 not null default now(),
  updated_at   timestamptz                 not null default now(),
  deleted_at   timestamptz,

  -- Constraints
  constraint coach_notes_content_length check (char_length(content) between 1 and 4000),
  constraint coach_notes_priority_range check (priority between -10 and 10),
  constraint coach_notes_action_url_valid check (action_url is null or public.is_valid_url(action_url))
);

comment on table public.coach_notes is 'AI-generated or admin-created coaching tips, nudges, and insights';

create index if not exists idx_coach_notes_user_id      on public.coach_notes (user_id);
create index if not exists idx_coach_notes_user_active  on public.coach_notes (user_id, created_at desc) where deleted_at is null;
create index if not exists idx_coach_notes_user_type    on public.coach_notes (user_id, type);
create index if not exists idx_coach_notes_priority     on public.coach_notes (user_id, priority desc, created_at desc)
  where deleted_at is null;
create index if not exists idx_coach_notes_expires_at   on public.coach_notes (expires_at)
  where expires_at is not null and deleted_at is null;

create trigger trg_coach_notes_set_updated_at
  before update on public.coach_notes
  for each row execute function public.set_updated_at();


-- 4.9 CONTACT / SUPPORT MESSAGES
create table if not exists public.contact_messages (
  id           uuid                        primary key default gen_random_uuid(),
  name         text                        not null,
  email        citext                      not null,
  subject      text,
  message      text                        not null,
  status       public.contact_status       not null default 'new',
  user_id      uuid                        references public.users(id) on delete set null,
  ip_address   inet,
  user_agent   text,
  assigned_to  uuid                        references public.users(id) on delete set null,
  resolved_at  timestamptz,
  created_at   timestamptz                 not null default now(),
  updated_at   timestamptz                 not null default now(),
  deleted_at   timestamptz,

  -- Constraints
  constraint contact_messages_name_length    check (char_length(name) between 1 and 100),
  constraint contact_messages_message_length check (char_length(message) between 10 and 5000),
  constraint contact_messages_email_valid    check (public.is_valid_email(email))
);

comment on table public.contact_messages is 'Support / inquiry / bug-report form submissions';

create index if not exists idx_contact_messages_status     on public.contact_messages (status);
create index if not exists idx_contact_messages_email      on public.contact_messages (email);
create index if not exists idx_contact_messages_user_id    on public.contact_messages (user_id)
  where user_id is not null;
create index if not exists idx_contact_messages_assigned   on public.contact_messages (assigned_to)
  where assigned_to is not null;
create index if not exists idx_contact_messages_created    on public.contact_messages (created_at desc);

create trigger trg_contact_messages_set_updated_at
  before update on public.contact_messages
  for each row execute function public.set_updated_at();


-- 4.10 NOTIFICATIONS (in-app feed)
create table if not exists public.notifications (
  id            uuid                        primary key default gen_random_uuid(),
  user_id       uuid                        not null references public.users(id) on delete cascade,
  type          public.notification_type      not null,
  title         text                        not null,
  body          text,
  link          text,
  payload       jsonb                       not null default '{}'::jsonb,
  read_at       timestamptz,
  created_at    timestamptz                 not null default now(),
  updated_at    timestamptz                 not null default now(),
  deleted_at    timestamptz,

  -- Constraints
  constraint notifications_title_length   check (char_length(title) between 1 and 200),
  constraint notifications_payload_obj    check (public.jsonb_is_object(payload)),
  constraint notifications_link_valid     check (link is null or public.is_valid_url(link))
);

comment on table public.notifications is 'In-app notification feed for users';

create index if not exists idx_notifications_user_id        on public.notifications (user_id, created_at desc);
create index if not exists idx_notifications_user_unread    on public.notifications (user_id)
  where read_at is null and deleted_at is null;
create index if not exists idx_notifications_type       on public.notifications (type);
create index if not exists idx_notifications_read_at        on public.notifications (user_id, read_at)
  where read_at is not null;
create index if not exists idx_notifications_deleted_at     on public.notifications (deleted_at)
  where deleted_at is not null;

create trigger trg_notifications_set_updated_at
  before update on public.notifications
  for each row execute function public.set_updated_at();


-- 4.11 NOTIFICATION PREFERENCES (1:1 with users)
create table if not exists public.notification_preferences (
  user_id              uuid        primary key references public.users(id) on delete cascade,
  weekly_summary       boolean     not null default true,
  recruiter_views      boolean     not null default true,
  verification_changes boolean     not null default false,
  opportunity_matches  boolean     not null default true,
  coach_tips           boolean     not null default false,
  product_updates      boolean     not null default true,
  digest_frequency     text        not null default 'daily',
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  -- Constraints
  constraint notification_preferences_digest_freq check (digest_frequency in ('realtime','daily','weekly','never'))
);

comment on table public.notification_preferences is 'Per-user notification channel and frequency preferences (1:1)';

create trigger trg_notification_prefs_set_updated_at
  before update on public.notification_preferences
  for each row execute function public.set_updated_at();


-- 4.12 USER INTEGRATIONS (OAuth-connected external platforms)
create table if not exists public.user_integrations (
  id                uuid                      primary key default gen_random_uuid(),
  user_id           uuid                      not null references public.users(id) on delete cascade,
  provider          public.auth_provider      not null,
  external_user_id   text,
  external_username  text,
  access_token      text,
  refresh_token     text,
  token_expires_at  timestamptz,
  scopes            text[]                    not null default '{}',
  status            public.integration_status not null default 'pending',
  last_synced_at    timestamptz,
  metadata          jsonb                     not null default '{}'::jsonb,
  created_at        timestamptz               not null default now(),
  updated_at        timestamptz               not null default now(),
  deleted_at        timestamptz,

  -- Constraints
  constraint user_integrations_uq_provider unique (user_id, provider),
  constraint user_integrations_metadata_is_obj check (public.jsonb_is_object(metadata)),
  constraint user_integrations_scopes_not_empty check (scopes <> '{}')
);

comment on table public.user_integrations is 'OAuth / API connections to external platforms (GitHub, Kaggle, Google, etc.)';

create index if not exists idx_user_integrations_user    on public.user_integrations (user_id);
create index if not exists idx_user_integrations_status  on public.user_integrations (status);
create index if not exists idx_user_integrations_provider on public.user_integrations (user_id, provider)
  where deleted_at is null;
create index if not exists idx_user_integrations_external on public.user_integrations (provider, external_user_id)
  where external_user_id is not null;

create trigger trg_user_integrations_set_updated_at
  before update on public.user_integrations
  for each row execute function public.set_updated_at();


-- 4.13 SUBSCRIPTIONS (plan / billing info, 1:1 with users)
create table if not exists public.subscriptions (
  id                     uuid                         primary key default gen_random_uuid(),
  user_id                uuid                         not null unique references public.users(id) on delete cascade,
  plan                   public.subscription_plan     not null default 'free',
  status                 public.subscription_status not null default 'active',
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  cancel_at_period_end   boolean                      not null default false,
  trial_ends_at          timestamptz,
  stripe_customer_id     text                         unique,
  stripe_subscription_id text                         unique,
  metadata               jsonb                        not null default '{}'::jsonb,
  created_at             timestamptz                  not null default now(),
  updated_at             timestamptz                  not null default now(),
  deleted_at             timestamptz,

  -- Constraints
  constraint subscriptions_metadata_is_object  check (public.jsonb_is_object(metadata)),
  constraint subscriptions_period_range         check (
    (current_period_start is null and current_period_end is null)
    or (current_period_start is not null and current_period_end is not null and current_period_end > current_period_start)
  )
);

comment on table public.subscriptions is 'Billing subscription plan and status (1:1 with users)';

create index if not exists idx_subscriptions_plan       on public.subscriptions (plan);
create index if not exists idx_subscriptions_status     on public.subscriptions (status);
create index if not exists idx_subscriptions_stripe_cust on public.subscriptions (stripe_customer_id)
  where stripe_customer_id is not null;
create index if not exists idx_subscriptions_trial_end  on public.subscriptions (trial_ends_at)
  where trial_ends_at is not null;
create index if not exists idx_subscriptions_period_end on public.subscriptions (current_period_end)
  where current_period_end is not null;

create trigger trg_subscriptions_set_updated_at
  before update on public.subscriptions
  for each row execute function public.set_updated_at();


-- 4.14 SAVED SEARCHES (user-saved opportunity filters)
create table if not exists public.saved_searches (
  id          uuid        primary key default gen_random_uuid(),
  user_id     uuid        not null references public.users(id) on delete cascade,
  name        text        not null,
  filters     jsonb       not null default '{}'::jsonb,
  notify_on_match boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- Constraints
  constraint saved_searches_name_length   check (char_length(name) between 1 and 100),
  constraint saved_searches_filters_obj   check (public.jsonb_is_object(filters))
);

comment on table public.saved_searches is 'User-saved opportunity search filters for quick re-query';

create index if not exists idx_saved_searches_user on public.saved_searches (user_id);

create trigger trg_saved_searches_set_updated_at
  before update on public.saved_searches
  for each row execute function public.set_updated_at();


-- 4.15 AUDIT LOG (admin security / compliance trail)
create table if not exists public.audit_log (
  id          uuid              primary key default gen_random_uuid(),
  actor_id    uuid              references public.users(id) on delete set null,
  actor_role  public.user_role,
  action      public.audit_action not null,
  entity_type text              not null,
  entity_id   text,
  old_data    jsonb,
  new_data    jsonb,
  ip_address  inet,
  user_agent  text,
  description text,
  created_at  timestamptz       not null default now(),

  -- Constraints
  constraint audit_log_entity_info check (char_length(entity_type) between 1 and 100)
);

comment on table public.audit_log is 'Immutable admin audit trail for security, compliance, and debugging';

create index if not exists idx_audit_log_actor       on public.audit_log (actor_id, created_at desc);
create index if not exists idx_audit_log_entity      on public.audit_log (entity_type, entity_id);
create index if not exists idx_audit_log_created_at  on public.audit_log (created_at desc);
create index if not exists idx_audit_log_action      on public.audit_log (action);
create index if not exists idx_audit_log_actor_role  on public.audit_log (actor_role, created_at desc);
create index if not exists idx_audit_log_brin        on public.audit_log using brin (created_at)
  with (pages_per_range = 32);


-- =============================================================================
-- 5. PARTITIONED TABLES  (must follow master table definition)
-- =============================================================================

-- 5.1 Create monthly partitions for proof_views (3 months ahead, 12 months back)
do $$
declare
  v_start  date := date_trunc('month', now()) - interval '12 months';
  v_end    date := date_trunc('month', now()) + interval '3 months';
  v_part   text;
  v_month  date;
  v_part_name text;
begin
  v_month := v_start;
  while v_month <= v_end loop
    v_part_name := 'proof_views_' || to_char(v_month, 'YYYY_MM');
    v_part := format(
      'create table if not exists public.%I partition of public.proof_views
       for values from (%L) to (%L)',
      v_part_name,
      v_month,
      v_month + interval '1 month'
    );
    execute v_part;
    v_month := v_month + interval '1 month';
  end loop;
end $$;

-- 5.2  Create FK-bearing clone table + trigger to maintain referential integrity
--      (partitioned tables cannot have direct FK references to them)
create table if not exists public.proof_views_fk (
  proof_id       uuid not null references public.proof_cards(id) on delete cascade,
  owner_id       uuid not null references public.users(id) on delete cascade,
  viewer_user_id uuid references public.users(id) on delete set null,
  viewed_at      timestamptz not null default now(),

  primary key (proof_id, viewed_at)
);

comment on table public.proof_views_fk is 'FK-enforcement mirror for partitioned proof_views (triggers sync)';

-- 5.3  Trigger to enforce FK via mirror table
create or replace function public.sync_proof_view_fk()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.proof_views_fk (proof_id, owner_id, viewer_user_id, viewed_at)
    values (new.proof_id, new.owner_id, new.viewer_user_id, new.viewed_at);
  elsif tg_op = 'DELETE' then
    delete from public.proof_views_fk where proof_id = old.proof_id and viewed_at = old.viewed_at;
  end if;
  return coalesce(new, old);
end $$;

create trigger trg_proof_views_sync_fk
  after insert or delete on public.proof_views
  for each row execute function public.sync_proof_view_fk();


-- =============================================================================
-- 6. CLEANUP  (migration from old naming / patterns)
-- =============================================================================
drop trigger if exists on_auth_user_created                  on auth.users;
drop trigger if exists trg_on_auth_user_created              on auth.users;
drop trigger if exists trg_auth_user_login                   on auth.users;
drop trigger if exists trg_user_default_subscription         on public.users;
drop trigger if exists trg_user_default_notification_prefs   on public.users;
drop trigger if exists trg_proof_cards_set_updated_at        on public.proof_cards;
drop trigger if exists trg_proof_views_set_updated_at        on public.proof_views;

drop function if exists public.handle_new_user()             cascade;
drop function if exists public.handle_new_profile()          cascade;
drop function if exists public.create_profile_for_user()     cascade;
drop function if exists public.fn_handle_new_auth_user()     cascade;
drop function if exists public.fn_touch_last_login()         cascade;
drop function if exists public.fn_create_default_subscription()     cascade;
drop function if exists public.fn_create_default_notification_prefs() cascade;
drop function if exists public.fn_set_updated_at()           cascade;
drop function if exists public.fn_slugify_username(text)     cascade;
drop function if exists public.fn_current_user_id()          cascade;
drop function if exists public.fn_current_user_role()        cascade;
drop function if exists public.fn_is_admin()                 cascade;
drop function if exists public.fn_increment_proof_view(uuid) cascade;
drop function if exists public.fn_proof_card_touch_timestamps() cascade;

-- =============================================================================
-- 7. TABLE-DEPENDENT FUNCTIONS  (+ triggers that reference them)
-- =============================================================================

-- 7.1  Resolve current public.users.id from auth.uid()
create or replace function public.current_user_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.users where auth_user_id = auth.uid() and deleted_at is null;
$$;

comment on function public.current_user_id() is 'Returns public.users.id for the currently authenticated auth.uid()';

-- 7.2  Resolve current user's role
create or replace function public.current_user_role()
returns public.user_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.users where auth_user_id = auth.uid() and deleted_at is null;
$$;

-- 7.3  True if caller has elevated privileges
create or replace function public.is_admin_or_mod()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.users
    where auth_user_id = auth.uid()
      and role in ('admin','moderator')
      and deleted_at is null
  );
$$;

-- 7.4  Validate user owns a proof card
create or replace function public.owns_proof(p_proof_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.proof_cards
    where id = p_proof_id and user_id = public.current_user_id() and deleted_at is null
  );
$$;

-- 7.5  Auto-increment proof card view_count on each new view
create or replace function public.increment_proof_view_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.proof_cards
     set view_count = view_count + 1
   where id = new.proof_id and deleted_at is null;
  return new;
end $$;

create trigger trg_proof_views_increment_count
  after insert on public.proof_views
  for each row execute function public.increment_proof_view_count();

-- 7.6  Auto-stamp verified_at on verification status transition
create or replace function public.stamp_verified_at()
returns trigger
language plpgsql
as $$
begin
  if new.verification_status = 'verified'
     and old.verification_status is distinct from 'verified' then
    new.verified_at := coalesce(new.verified_at, now());
  end if;
  return new;
end $$;

create trigger trg_proof_cards_stamp_verified
  before update of verification_status on public.proof_cards
  for each row when (new.verification_status = 'verified')
  execute function public.stamp_verified_at();

-- 7.7  Auto-create public.users row on auth.users INSERT  (handles email + OAuth)
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_full_name text;
  v_username  text;
  v_base      text;
  v_suffix    text;
  v_provider  text;
  v_max_tries constant smallint := 5;
  v_try       smallint := 0;
begin
  v_full_name := coalesce(new.raw_user_meta_data->>'full_name', '');
  v_base := case
              when v_full_name != '' then v_full_name
              else split_part(new.email, '@', 1)
            end;
  v_username := public.slugify_username(v_base);
  if length(v_username) < 3 then
    v_username := 'user';
  end if;

  v_suffix := substr(replace(new.id::text, '-', ''), 1, 6);

  v_provider := coalesce(new.raw_app_meta_data->>'provider', 'email');

  loop
    begin
      insert into public.users (auth_user_id, email, username, full_name, avatar_url,
                                role, account_status, auth_provider)
      values (new.id, new.email, v_username, nullif(v_full_name, ''),
              nullif(new.raw_user_meta_data->>'avatar_url', ''),
              'user', 'active',
              case
                when v_provider = 'google'  then 'google'::public.auth_provider
                when v_provider = 'github'  then 'github'::public.auth_provider
                when v_provider = 'apple'   then 'apple'::public.auth_provider
                when v_provider = 'linkedin' then 'linkedin'::public.auth_provider
                else 'email'::public.auth_provider
              end);
      return new;
    exception
      when unique_violation then
        v_try := v_try + 1;
        if v_try >= v_max_tries then
          raise exception 'Could not create user profile after % attempts (username: %)', v_max_tries, v_username;
        end if;
        v_username := left(v_username, 23) || '-' || v_suffix;
    end;
  end loop;
end $$;

create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- 7.8  Track last_login_at on public.users
create or replace function public.touch_last_login()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.last_sign_in_at is distinct from old.last_sign_in_at then
    update public.users
       set last_login_at = new.last_sign_in_at
     where auth_user_id = new.id;
  end if;
  return new;
end $$;

create trigger trg_auth_user_login
  after update of last_sign_in_at on auth.users
  for each row execute function public.touch_last_login();

-- 7.9  Auto-create free subscription for new users
create or replace function public.create_default_subscription()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.subscriptions (user_id, plan, status)
  values (new.id, 'free', 'active')
  on conflict (user_id) do nothing;
  return new;
end $$;

create trigger trg_user_default_subscription
  after insert on public.users
  for each row execute function public.create_default_subscription();

-- 7.10  Auto-create notification preferences for new users
create or replace function public.create_default_notification_prefs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end $$;

create trigger trg_user_default_notification_prefs
  after insert on public.users
  for each row execute function public.create_default_notification_prefs();

-- 7.11  Audit trigger — generic table-level change tracking
create or replace function public.audit_table_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.audit_action;
  v_new_data jsonb;
  v_old_data jsonb;
begin
  if tg_op = 'INSERT' then
    v_action := 'create';
    v_new_data := row_to_json(new)::jsonb;
    v_old_data := null;
  elsif tg_op = 'UPDATE' then
    v_action := 'update';
    v_new_data := row_to_json(new)::jsonb;
    v_old_data := row_to_json(old)::jsonb;
  elsif tg_op = 'DELETE' then
    v_action := 'delete';
    v_new_data := null;
    v_old_data := row_to_json(old)::jsonb;
  end if;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, old_data, new_data)
  values (
    public.current_user_id(),
    public.current_user_role(),
    v_action,
    tg_table_name,
    coalesce(new.id::text, old.id::text),
    v_old_data,
    v_new_data
  );

  return coalesce(new, old);
end $$;

comment on function public.audit_table_change() is 'Generic trigger function to log all mutations to audit_log. Attach with: CREATE TRIGGER ... FOR each row EXECUTE FUNCTION audit_table_change();';

-- 7.12  Prevent resurrecting soft-deleted rows
create or replace function public.prevent_soft_delete_resurrect()
returns trigger
language plpgsql
as $$
begin
  if old.deleted_at is not null then
    raise exception 'Cannot modify a soft-deleted record (id=%). Restore first.', old.id
      using hint = 'Set deleted_at to null to restore the record.';
  end if;
  return new;
end $$;

comment on function public.prevent_soft_delete_resurrect() is
  'Attach as BEFORE UPDATE trigger on any table with deleted_at to block writes to soft-deleted rows';


-- =============================================================================
-- 8. ROW-LEVEL SECURITY
-- =============================================================================

-- 8.0  Enable RLS on every table
do $$ begin
  execute (
    select string_agg(
      format('alter table public.%I enable row level security;', tablename),
      ' '
    )
    from pg_tables
    where schemaname = 'public' and tablename not like 'proof_views_%'
  );
end $$;

-- Reset: drop all existing policies first
do $$ declare
  v_rec record;
begin
  for v_rec in (
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
  ) loop
    execute format('drop policy if exists %I on %I.%I;',
                   v_rec.policyname, v_rec.schemaname, v_rec.tablename);
  end loop;
end $$;

-- 8.1 USERS
create policy users_select_public on public.users for select
  using (deleted_at is null and is_profile_public = true and account_status = 'active');
create policy users_select_self   on public.users for select
  using (auth_user_id = auth.uid());
create policy users_insert_self   on public.users for insert
  with check (auth_user_id = auth.uid());
create policy users_update_self   on public.users for update
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());
create policy users_delete_self   on public.users for delete
  using (auth_user_id = auth.uid());
create policy users_admin_all     on public.users for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.2 PROOF CARDS
create policy proof_cards_select_public on public.proof_cards for select
  using (
    deleted_at is null
    and visibility = 'public'
    and verification_status = 'verified'
    and exists (
      select 1 from public.users u
      where u.id = proof_cards.user_id
        and u.deleted_at is null
        and u.is_profile_public = true
        and u.account_status = 'active'
    )
  );
create policy proof_cards_select_owner on public.proof_cards for select
  using (user_id = public.current_user_id() and deleted_at is null);
create policy proof_cards_insert_owner on public.proof_cards for insert
  with check (user_id = public.current_user_id());
create policy proof_cards_update_owner on public.proof_cards for update
  using (user_id = public.current_user_id() and deleted_at is null)
  with check (user_id = public.current_user_id());
create policy proof_cards_delete_owner on public.proof_cards for delete
  using (user_id = public.current_user_id());
create policy proof_cards_admin_all   on public.proof_cards for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.3 PROOF SOURCES
create policy proof_sources_select_owner on public.proof_sources for select
  using (user_id = public.current_user_id() and deleted_at is null);
create policy proof_sources_insert_owner on public.proof_sources for insert
  with check (user_id = public.current_user_id());
create policy proof_sources_update_owner on public.proof_sources for update
  using (user_id = public.current_user_id() and deleted_at is null)
  with check (user_id = public.current_user_id());
create policy proof_sources_delete_owner on public.proof_sources for delete
  using (user_id = public.current_user_id());
create policy proof_sources_admin_all   on public.proof_sources for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.4 PROOF SHARES
create policy proof_shares_owner_all on public.proof_shares for all
  using (owner_id = public.current_user_id())
  with check (owner_id = public.current_user_id());
create policy proof_shares_admin_all on public.proof_shares for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.5 PROOF VIEWS (partitioned)
create policy proof_views_select_owner on public.proof_views for select
  using (owner_id = public.current_user_id());
create policy proof_views_insert_any   on public.proof_views for insert
  with check (true);
create policy proof_views_admin_all    on public.proof_views for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.6 OPPORTUNITIES
create policy opportunities_select_active on public.opportunities for select
  using (is_active = true and deleted_at is null);
create policy opportunities_insert_admin on public.opportunities for insert
  with check (public.is_admin_or_mod());
create policy opportunities_update_admin on public.opportunities for update
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());
create policy opportunities_delete_admin on public.opportunities for delete
  using (public.is_admin_or_mod());

-- 8.7 USER OPPORTUNITIES
create policy user_opportunities_owner_all on public.user_opportunities for all
  using (user_id = public.current_user_id())
  with check (user_id = public.current_user_id());
create policy user_opportunities_admin_all on public.user_opportunities for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.8 COACH NOTES
create policy coach_notes_select_self on public.coach_notes for select
  using (user_id = public.current_user_id() and deleted_at is null);
create policy coach_notes_insert_self on public.coach_notes for insert
  with check (user_id = public.current_user_id());
create policy coach_notes_update_self on public.coach_notes for update
  using (user_id = public.current_user_id() and deleted_at is null)
  with check (user_id = public.current_user_id());
create policy coach_notes_delete_self on public.coach_notes for delete
  using (user_id = public.current_user_id());
create policy coach_notes_admin_all   on public.coach_notes for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.9 CONTACT MESSAGES
create policy contact_messages_insert_anon on public.contact_messages for insert
  with check (true);
create policy contact_messages_select_admin on public.contact_messages for select
  using (public.is_admin_or_mod());
create policy contact_messages_update_admin on public.contact_messages for update
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());
create policy contact_messages_delete_admin on public.contact_messages for delete
  using (public.is_admin_or_mod());

-- 8.10 NOTIFICATIONS
create policy notifications_owner_all on public.notifications for all
  using (user_id = public.current_user_id())
  with check (user_id = public.current_user_id());
create policy notifications_admin_all on public.notifications for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.11 NOTIFICATION PREFERENCES
create policy notification_preferences_owner_all on public.notification_preferences for all
  using (user_id = public.current_user_id())
  with check (user_id = public.current_user_id());
create policy notification_preferences_admin_all on public.notification_preferences for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.12 USER INTEGRATIONS
create policy user_integrations_owner_all on public.user_integrations for all
  using (user_id = public.current_user_id())
  with check (user_id = public.current_user_id());
create policy user_integrations_admin_all on public.user_integrations for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.13 SUBSCRIPTIONS
create policy subscriptions_owner_select on public.subscriptions for select
  using (user_id = public.current_user_id());
create policy subscriptions_owner_insert on public.subscriptions for insert
  with check (user_id = public.current_user_id());
create policy subscriptions_owner_update on public.subscriptions for update
  using (user_id = public.current_user_id())
  with check (user_id = public.current_user_id());
create policy subscriptions_admin_all on public.subscriptions for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.14 SAVED SEARCHES
create policy saved_searches_owner_all on public.saved_searches for all
  using (user_id = public.current_user_id())
  with check (user_id = public.current_user_id());
create policy saved_searches_admin_all on public.saved_searches for all
  using (public.is_admin_or_mod())
  with check (public.is_admin_or_mod());

-- 8.15 AUDIT LOG
create policy audit_log_admin_select on public.audit_log for select
  using (public.is_admin_or_mod());
create policy audit_log_admin_insert on public.audit_log for insert
  with check (public.is_admin_or_mod());


-- =============================================================================
-- 9. STORAGE BUCKETS + POLICIES
-- =============================================================================
insert into storage.buckets (id, name, public)
values
  ('avatars',     'avatars',     true),
  ('proof-files', 'proof-files', false),
  ('covers',      'covers',      true)
on conflict (id) do nothing;

-- Clear existing storage policies for these buckets
do $$ declare
  v_rec record;
begin
  for v_rec in (
    select policyname from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname like 'avatars%' or policyname like 'proof-files%' or policyname like 'covers%'
  ) loop
    execute format('drop policy if exists %I on storage.objects;', v_rec.policyname);
  end loop;
end $$;

-- Avatars
create policy "avatars_select" on storage.objects for select
  using (bucket_id = 'avatars');
create policy "avatars_insert" on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "avatars_update" on storage.objects for update
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "avatars_delete" on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Proof files
create policy "proof_files_select" on storage.objects for select
  using (
    bucket_id = 'proof-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "proof_files_insert" on storage.objects for insert
  with check (
    bucket_id = 'proof-files'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "proof_files_update" on storage.objects for update
  using (
    bucket_id = 'proof-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "proof_files_delete" on storage.objects for delete
  using (
    bucket_id = 'proof-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Covers
create policy "covers_select" on storage.objects for select
  using (bucket_id = 'covers');
create policy "covers_insert" on storage.objects for insert
  with check (bucket_id = 'covers' and auth.role() = 'authenticated');
create policy "covers_update" on storage.objects for update
  using (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "covers_delete" on storage.objects for delete
  using (
    bucket_id = 'covers'
    and (storage.foldername(name))[1] = auth.uid()::text
  );


-- =============================================================================
-- 10. GRANTS & DEFAULT PRIVILEGES
-- =============================================================================
grant usage    on schema public to anon, authenticated, service_role;
grant all      on schema public to service_role;

-- Anon: only insert contact tickets, select from public-facing views
grant insert on public.contact_messages to anon;
grant select on storage.objects to anon;

-- Authenticated: full CRUD on own data via RLS
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

-- Service_role: unrestricted
grant all on all tables    in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;

-- Default privileges for future objects
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant usage, select on sequences to authenticated;
alter default privileges in schema public
  grant execute on functions to authenticated;

alter default privileges in schema public
  grant all on tables    to service_role;
alter default privileges in schema public
  grant all on sequences to service_role;
alter default privileges in schema public
  grant all on functions  to service_role;


-- =============================================================================
-- 11. REALTIME PUBLICATION
-- =============================================================================
do $$
declare
  v_tables text[] := array['proof_cards','opportunities','notifications','coach_notes'];
  v_t     text;
begin
  foreach v_t in array v_tables loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_t
    ) then
      execute format('alter publication supabase_realtime add table public.%I;', v_t);
    end if;
  end loop;
end $$;


-- =============================================================================
-- 12. VIEWS
-- =============================================================================

-- 12.1  Public user profile view (flattened)
create or replace view public.user_profiles as
select
  u.id,
  u.username,
  u.full_name,
  u.avatar_url,
  u.headline,
  u.bio,
  u.location,
  u.college,
  u.year,
  u.website_url,
  u.github_url,
  u.linkedin_url,
  u.twitter_url,
  u.created_at                                       as member_since,
  coalesce(
    (select jsonb_agg(
       jsonb_build_object(
         'id', pc.id,
         'title', pc.title,
         'description', pc.description,
         'source_type', pc.source_type,
         'source_url', pc.source_url,
         'thumbnail_url', pc.thumbnail_url,
         'skills', pc.skills_extracted || pc.skills_user_added,
         'what_it_proves', pc.what_it_proves,
         'view_count', pc.view_count,
         'created_at', pc.created_at
       )
       order by pc.sort_order, pc.created_at desc
     )
     from public.proof_cards pc
     where pc.user_id = u.id
       and pc.visibility = 'public'
       and pc.verification_status = 'verified'
       and pc.deleted_at is null
    ),
    '[]'::jsonb
  )                                                 as public_proofs,
  coalesce(
    (select array_agg(distinct trim(s))
     from public.proof_cards pc,
          lateral unnest(pc.skills_extracted || pc.skills_user_added) as s
     where pc.user_id = u.id
       and pc.visibility = 'public'
       and pc.verification_status = 'verified'
       and pc.deleted_at is null
       and trim(s) != ''
    ),
    '{}'::text[]
  )                                                 as public_skills,
  coalesce(
    (select count(*) from public.proof_views pv where pv.owner_id = u.id),
    0
  )::integer                                        as total_profile_views,
  row_number() over (order by u.created_at desc)     as profile_rank
from public.users u
where u.deleted_at is null
  and u.is_profile_public = true
  and u.account_status = 'active';

comment on view public.user_profiles is
  'Security-barrier view of public user profiles with proofs, skills, and view counts';
comment on column public.user_profiles.profile_rank is 'Approximate rank by join date (for discoverability features)';

-- 12.2  User dashboard view (aggregated stats per user)
create or replace view public.user_dashboard as
select
  u.id                                                              as user_id,
  count(distinct pc.id) filter (where pc.deleted_at is null)        as total_proofs,
  count(distinct pc.id) filter (
    where pc.visibility = 'public' and pc.deleted_at is null
  )                                                                 as public_proofs,
  count(distinct pc.id) filter (
    where pc.verification_status = 'verified' and pc.deleted_at is null
  )                                                                 as verified_proofs,
  count(distinct ps.id) filter (where ps.deleted_at is null)        as total_sources,
  count(distinct ps.id) filter (
    where ps.is_connected = true and ps.deleted_at is null
  )                                                                 as connected_sources,
  coalesce(sum(pv_count.cnt), 0)::integer                           as total_profile_views,
  count(distinct uo.id) filter (where uo.status = 'saved')          as saved_opportunities,
  count(distinct uo.id) filter (where uo.status = 'applied')        as applied_opportunities,
  count(distinct n.id) filter (where n.read_at is null
    and n.deleted_at is null)                                       as unread_notifications
from public.users u
left join public.proof_cards pc          on pc.user_id = u.id
left join public.proof_sources ps        on ps.user_id = u.id
left join public.user_opportunities uo   on uo.user_id = u.id
left join public.notifications n         on n.user_id = u.id
left join lateral (
  select count(*) as cnt
  from public.proof_views pv
  where pv.owner_id = u.id
) pv_count on true
where u.deleted_at is null
group by u.id;

comment on view public.user_dashboard is 'Aggregated dashboard stats per user (used by the /dashboard API)';

-- 12.3  Opportunity detail view (with user match status)
create or replace view public.opportunity_details as
select
  o.*,
  coalesce(uo.status::text, 'unsaved')                               as my_status,
  uo.match_score                                                    as my_match_score,
  uo.applied_at                                                     as my_applied_at,
  uo.notes                                                          as my_notes
from public.opportunities o
left join public.user_opportunities uo
  on uo.opportunity_id = o.id
  and uo.user_id = public.current_user_id()
where o.deleted_at is null;

comment on view public.opportunity_details is 'Opportunities with the current user''s interaction status appended';


-- =============================================================================
-- 13. MATERIALIZED VIEWS  (for dashboards/analytics)
-- =============================================================================

-- 13.1  Analytics snapshot (platform-wide stats, periodically refreshed)
create materialized view if not exists public.platform_analytics as
select
  now()::date                                                       as snapshot_date,
  (select count(*) from public.users
   where deleted_at is null and account_status = 'active')           as active_users,
  (select count(*) from public.users
   where deleted_at is null and account_status = 'active'
     and created_at >= now() - interval '7 days')                   as new_users_7d,
  (select count(*) from public.users
   where deleted_at is null and year is not null)                   as students_with_profile,
  (select count(*) from public.proof_cards where deleted_at is null) as total_proofs,
  (select count(*) from public.proof_cards
   where deleted_at is null and verification_status = 'verified')    as verified_proofs,
  (select count(*) from public.proof_cards
   where deleted_at is null and verification_status = 'pending')     as pending_proofs,
  (select count(*) from public.opportunities
   where deleted_at is null and is_active = true)                    as active_opportunities,
  (select count(*) from public.proof_views)                          as total_views,
  (select count(*) from public.proof_views
   where viewed_at >= now() - interval '7 days')                     as views_7d,
  (select count(*) from public.contact_messages
   where status = 'new')                                             as unresolved_tickets;

comment on materialized view public.platform_analytics is
  'Cached platform-wide analytics snapshot. Refresh with: refresh materialized view concurrently public.platform_analytics;';

create unique index if not exists idx_platform_analytics_snapshot
  on public.platform_analytics (snapshot_date);

-- 13.2  Refresh function (call from cron or admin panel)
create or replace function public.refresh_platform_analytics()
returns void
language sql
security definer
set search_path = public
as $$
  refresh materialized view concurrently public.platform_analytics;
$$;

comment on function public.refresh_platform_analytics() is
  'Call this from pg_cron or an admin endpoint to refresh the analytics materialized view';


-- =============================================================================
-- 14. SEED DATA  (idempotent — safe to re-run)
-- =============================================================================

insert into public.opportunities (id, title, company, company_logo_url, type, required_skills, nice_to_have, description, location, is_remote, link, apply_deadline, match_percentage, salary_min, salary_max, salary_currency, is_active, posted_at)
values
  ('00000000-0000-0000-0000-000000000001',
   'Backend Engineering Intern', 'Amazon', null, 'internship',
   array['Node.js','PostgreSQL','REST APIs'], array['AWS','Docker'],
   'Work on scalable backend services powering Amazon''s core platform. Design and implement RESTful APIs, optimize database queries, and collaborate with senior engineers on production systems.',
   'Bengaluru, India', false, 'https://amazon.jobs/backend-intern',
   now() + interval '45 days', 82, 50000, 80000, 'USD', true, now()),
  ('00000000-0000-0000-0000-000000000002',
   'Software Engineer - New Grad', 'Flipkart', null, 'job',
   array['System Design','REST APIs','Java'], array['Microservices','Kubernetes'],
   'Full-time role building e-commerce infrastructure at scale. Work on distributed systems, high-throughput APIs, and real-time data pipelines.',
   'Bengaluru, India', false, 'https://flipkart.careers/new-grad',
   now() + interval '30 days', 76, 30000, 50000, 'USD', true, now()),
  ('00000000-0000-0000-0000-000000000003',
   'ML Research Apprenticeship', 'Google', null, 'mentorship',
   array['Python','Transformers','PyTorch'], array['TensorFlow','GCP'],
   'Research apprenticeship in machine learning at Google DeepMind. Work alongside world-class researchers on cutting-edge AI problems.',
   'Remote', true, 'https://careers.google.com/ml-apprenticeship',
   now() + interval '60 days', 69, null, null, 'USD', true, now()),
  ('00000000-0000-0000-0000-000000000004',
   'Open Source Grant', 'GitHub', null, 'scholarship',
   array['Open Source','Git','Documentation'], array['Community Management'],
   'Funding for open source maintainers and contributors. Support your project and grow the open source ecosystem.',
   'Remote', true, 'https://github.com/sponsors/grants',
   now() + interval '90 days', 55, 10000, 50000, 'USD', true, now()),
  ('00000000-0000-0000-0000-000000000005',
   'Smart India Hackathon 2025', 'SIH', null, 'hackathon',
   array['Full Stack','Problem Solving','IoT'], array['ML','Cloud'],
   'India''s largest hackathon. Build innovative solutions for real-world challenges posed by government ministries.',
   'Pan India', false, 'https://sih.gov.in',
   now() + interval '120 days', 60, null, null, 'INR', true, now()),
  ('00000000-0000-0000-0000-000000000006',
   'UX Research Intern', 'Microsoft', null, 'internship',
   array['User Research','Figma','Prototyping'], array['Design Systems','A11y'],
   'Conduct user research, create wireframes and prototypes, and collaborate with product teams to shape Microsoft experiences.',
   'Hyderabad, India', false, 'https://careers.microsoft.com/ux-intern',
   now() + interval '50 days', 45, 6000, 9000, 'USD', true, now())
on conflict (id) do update set
  title             = excluded.title,
  company           = excluded.company,
  type              = excluded.type,
  required_skills   = excluded.required_skills,
  nice_to_have      = excluded.nice_to_have,
  match_percentage  = excluded.match_percentage,
  link              = excluded.link,
  apply_deadline    = excluded.apply_deadline,
  is_active         = excluded.is_active,
  salary_min        = excluded.salary_min,
  salary_max        = excluded.salary_max,
  description       = excluded.description;

-- =============================================================================
-- 15. VERIFICATION
-- =============================================================================
-- Run these queries after applying the schema:
--
--   select tablename, rowsecurity
--   from pg_tables
--   where schemaname = 'public'
--   order by tablename;
--
--   select policyname, tablename, permissive, cmd, qual, with_check
--   from pg_policies
--   where schemaname = 'public'
--   order by tablename, policyname;
--
--   select proname, prosecdef, provolatile
--   from pg_proc
--   where pronamespace = 'public'::regnamespace
--   order by proname;
--
--   select relname, relkind
--   from pg_class
--   where relnamespace = 'public'::regnamespace
--     and relkind in ('v','m')
--   order by relkind, relname;
