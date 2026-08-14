-- Supabase schema for the SQLite database in app_database.dart
-- Paste this entire file into Supabase SQL Editor and click Run.

create extension if not exists pgcrypto;

-- =========================
-- Authentication profile
-- =========================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  email text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists email text;
create index if not exists profiles_display_name_search_idx
on public.profiles (lower(display_name));
create index if not exists profiles_email_search_idx
on public.profiles (lower(email));

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, email, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'display_name',
      new.raw_user_meta_data ->> 'full_name',
      split_part(coalesce(new.email, ''), '@', 1)
    ),
    new.email,
    coalesce(
      new.raw_user_meta_data ->> 'avatar_url',
      new.raw_user_meta_data ->> 'picture'
    )
  )
  on conflict (id) do update set
    email = excluded.email,
    display_name = case
      when coalesce(public.profiles.display_name, '') = '' then excluded.display_name
      else public.profiles.display_name
    end,
    avatar_url = coalesce(public.profiles.avatar_url, excluded.avatar_url);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- Payloads shared directly between signed-in FlashCard users. Recipients only
-- receive a portable snapshot; the sender's own course rows stay private.
create table if not exists public.course_shares (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  item_type text not null check (item_type in ('course', 'topic')),
  title text not null,
  payload jsonb not null,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  opened_at timestamptz,
  responded_at timestamptz,
  check (sender_id <> recipient_id)
);

alter table public.course_shares
add column if not exists status text not null default 'pending';
alter table public.course_shares
add column if not exists responded_at timestamptz;

create index if not exists course_shares_recipient_created_idx
on public.course_shares (recipient_id, created_at desc);
create index if not exists course_shares_recipient_status_idx
on public.course_shares (recipient_id, status, created_at desc);
create index if not exists course_shares_sender_created_idx
on public.course_shares (sender_id, created_at desc);

-- Realtime drives the red notification badge without polling.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'course_shares'
  ) then
    alter publication supabase_realtime add table public.course_shares;
  end if;
end;
$$;

-- =========================
-- Shared language catalogue
-- =========================
create table if not exists public.languages (
  id smallint generated always as identity primary key,
  name text not null,
  native_name text,
  code text not null unique,
  tts_code text,
  script_type text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.languages (name, native_name, code, tts_code, script_type)
values
  ('Tiếng Trung Phồn thể', '繁體中文', 'zh-TW', 'zh-TW', 'traditional'),
  ('Tiếng Trung Giản thể', '简体中文', 'zh-CN', 'zh-CN', 'simplified'),
  ('Tiếng Anh', 'English', 'en-US', 'en-US', 'latin'),
  ('Tiếng Đức', 'Deutsch', 'de-DE', 'de-DE', 'latin'),
  ('Tiếng Nhật', '日本語', 'ja-JP', 'ja-JP', 'japanese'),
  ('Tiếng Hàn', '한국어', 'ko-KR', 'ko-KR', 'korean'),
  ('Tiếng Việt', 'Tiếng Việt', 'vi-VN', 'vi-VN', 'latin')
on conflict (code) do nothing;

-- =========================
-- User-owned learning data
-- UUID ids avoid collisions between web, phones and offline SQLite databases.
-- =========================
create table if not exists public.topics (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null default 1,
  last_device_id text,
  last_mutation_id uuid,
  unique (id, owner_id)
);

create unique index if not exists topics_owner_name_unique
on public.topics (owner_id, lower(trim(name))) where deleted_at is null;

create table if not exists public.courses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  topic_id uuid,
  title text not null,
  description text,
  language_id smallint references public.languages(id),
  language_name text,
  language_code text not null,
  card_count integer not null default 0 check (card_count >= 0),
  is_favorite boolean not null default false,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null default 1,
  last_device_id text,
  last_mutation_id uuid,
  unique (id, owner_id),
  foreign key (topic_id, owner_id)
    references public.topics(id, owner_id) on delete set null (topic_id)
);

create unique index if not exists courses_owner_title_unique
on public.courses (owner_id, lower(trim(title))) where deleted_at is null;
create index if not exists courses_owner_topic_idx on public.courses(owner_id, topic_id);
create index if not exists courses_owner_language_idx on public.courses(owner_id, language_code);

create table if not exists public.cards (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  course_id uuid not null,
  term text not null,
  definition text not null,
  pronunciation text,
  raw_text text,
  input_format text,
  extra_meaning text,
  note text,
  image_path text,
  audio_path text,
  position integer not null default 0,
  is_favorite boolean not null default false,
  is_hidden boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null default 1,
  last_device_id text,
  last_mutation_id uuid,
  unique (id, owner_id),
  foreign key (course_id, owner_id)
    references public.courses(id, owner_id) on delete cascade
);

create index if not exists cards_owner_course_position_idx
on public.cards(owner_id, course_id, position);
create index if not exists cards_owner_term_idx on public.cards(owner_id, term);
create index if not exists cards_owner_pronunciation_idx on public.cards(owner_id, pronunciation);

create table if not exists public.card_examples (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  card_id uuid not null,
  example_text text not null,
  pronunciation text,
  meaning text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null default 1,
  last_device_id text,
  last_mutation_id uuid,
  unique (id, owner_id),
  foreign key (card_id, owner_id)
    references public.cards(id, owner_id) on delete cascade
);

create index if not exists card_examples_owner_card_idx
on public.card_examples(owner_id, card_id);

create table if not exists public.tags (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  color text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id)
);

create unique index if not exists tags_owner_name_unique
on public.tags(owner_id, lower(trim(name)));

create table if not exists public.course_tags (
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  course_id uuid not null,
  tag_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, course_id, tag_id),
  foreign key (course_id, owner_id)
    references public.courses(id, owner_id) on delete cascade,
  foreign key (tag_id, owner_id)
    references public.tags(id, owner_id) on delete cascade
);

create table if not exists public.review_states (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  card_id uuid not null,
  level integer not null default 0,
  ease_factor double precision not null default 2.5,
  interval_days integer not null default 0,
  repetition_count integer not null default 0,
  correct_count integer not null default 0,
  wrong_count integer not null default 0,
  last_reviewed_at timestamptz,
  next_review_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  revision bigint not null default 1,
  last_device_id text,
  last_mutation_id uuid,
  unique (id, owner_id),
  unique (owner_id, card_id),
  foreign key (card_id, owner_id)
    references public.cards(id, owner_id) on delete cascade
);

create index if not exists review_states_owner_due_idx
on public.review_states(owner_id, next_review_at);

create table if not exists public.study_sessions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  course_id uuid not null,
  mode text not null,
  total_cards integer not null default 0,
  correct_count integer not null default 0,
  wrong_count integer not null default 0,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  foreign key (course_id, owner_id)
    references public.courses(id, owner_id) on delete cascade
);

create index if not exists study_sessions_owner_course_idx
on public.study_sessions(owner_id, course_id, started_at desc);

create table if not exists public.study_results (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  session_id uuid not null,
  card_id uuid not null,
  answer_text text,
  is_correct boolean not null,
  response_time_ms integer,
  reviewed_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  foreign key (session_id, owner_id)
    references public.study_sessions(id, owner_id) on delete cascade,
  foreign key (card_id, owner_id)
    references public.cards(id, owner_id) on delete cascade
);

create index if not exists study_results_owner_card_idx
on public.study_results(owner_id, card_id, reviewed_at desc);

create table if not exists public.review_sentence_questions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  course_id uuid not null,
  card_id uuid not null,
  language_code text not null,
  direction text not null,
  source_term text not null,
  source_definition text not null,
  question text not null,
  answer text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  unique (owner_id, course_id, card_id, language_code, direction),
  foreign key (course_id, owner_id)
    references public.courses(id, owner_id) on delete cascade,
  foreign key (card_id, owner_id)
    references public.cards(id, owner_id) on delete cascade
);

create index if not exists review_questions_owner_course_idx
on public.review_sentence_questions(owner_id, course_id, language_code, direction);

create table if not exists public.import_exports (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  type text not null,
  file_name text,
  file_path text,
  format text not null,
  course_id uuid,
  status text not null,
  message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_id),
  foreign key (course_id, owner_id)
    references public.courses(id, owner_id) on delete set null (course_id)
);

create table if not exists public.app_settings (
  owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  key text not null,
  value text not null,
  updated_at timestamptz not null default now(),
  primary key (owner_id, key)
);

-- =========================
-- Keep updated_at current
-- =========================
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'profiles', 'languages', 'topics', 'courses', 'cards', 'card_examples',
    'tags', 'review_states', 'study_sessions', 'study_results',
    'review_sentence_questions', 'import_exports', 'app_settings'
  ] loop
    execute format('drop trigger if exists set_updated_at on public.%I', table_name);
    execute format(
      'create trigger set_updated_at before update on public.%I '
      'for each row execute function public.set_updated_at()',
      table_name
    );
  end loop;
end;
$$;

-- =========================
-- Row Level Security
-- Learning rows remain private. Authenticated users may discover profiles,
-- while share payloads are visible only to their sender and recipient.
-- =========================
alter table public.profiles enable row level security;
alter table public.course_shares enable row level security;
alter table public.languages enable row level security;
alter table public.topics enable row level security;
alter table public.courses enable row level security;
alter table public.cards enable row level security;
alter table public.card_examples enable row level security;
alter table public.tags enable row level security;
alter table public.course_tags enable row level security;
alter table public.review_states enable row level security;
alter table public.study_sessions enable row level security;
alter table public.study_results enable row level security;
alter table public.review_sentence_questions enable row level security;
alter table public.import_exports enable row level security;
alter table public.app_settings enable row level security;

drop policy if exists profiles_own_rows on public.profiles;
create policy profiles_own_rows on public.profiles
for all to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists profiles_authenticated_read on public.profiles;
create policy profiles_authenticated_read on public.profiles
for select to authenticated
using (true);

drop policy if exists course_shares_read on public.course_shares;
create policy course_shares_read on public.course_shares
for select to authenticated
using (sender_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists course_shares_send on public.course_shares;
create policy course_shares_send on public.course_shares
for insert to authenticated
with check (sender_id = auth.uid() and recipient_id <> auth.uid());

drop policy if exists course_shares_recipient_update on public.course_shares;
create policy course_shares_recipient_update on public.course_shares
for update to authenticated
using (recipient_id = auth.uid())
with check (recipient_id = auth.uid());

drop policy if exists course_shares_delete on public.course_shares;
create policy course_shares_delete on public.course_shares
for delete to authenticated
using (sender_id = auth.uid() or recipient_id = auth.uid());

drop policy if exists languages_read on public.languages;
create policy languages_read on public.languages
for select to authenticated
using (true);

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'topics', 'courses', 'cards', 'card_examples', 'tags', 'course_tags',
    'review_states', 'study_sessions', 'study_results',
    'review_sentence_questions', 'import_exports', 'app_settings'
  ] loop
    execute format('drop policy if exists own_rows on public.%I', table_name);
    execute format(
      'create policy own_rows on public.%I for all to authenticated '
      'using (owner_id = auth.uid()) with check (owner_id = auth.uid())',
      table_name
    );
  end loop;
end;
$$;

-- Existing Auth users (created before this migration) also receive a profile.
insert into public.profiles (id, display_name, email, avatar_url)
select
  id,
  coalesce(
    raw_user_meta_data ->> 'display_name',
    raw_user_meta_data ->> 'full_name',
    split_part(coalesce(email, ''), '@', 1)
  ),
  email,
  coalesce(
    raw_user_meta_data ->> 'avatar_url',
    raw_user_meta_data ->> 'picture'
  )
from auth.users
on conflict (id) do update set
  email = excluded.email,
  display_name = case
    when coalesce(public.profiles.display_name, '') = '' then excluded.display_name
    else public.profiles.display_name
  end,
  avatar_url = coalesce(public.profiles.avatar_url, excluded.avatar_url);
