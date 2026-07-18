-- School View — Phase 1 Schema
-- Postgres / Supabase

-- ============================================================
-- SCHOOLS
-- ============================================================
create table schools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  city text,
  state text,
  zip text,
  district text,
  grade_levels text,          -- e.g. "K-5", "6-8", "9-12"
  phone text,
  website text,
  source text not null,       -- 'doe', 'nces', 'district_export', 'manual'
  source_id text,             -- original ID from the source dataset, for de-duping re-imports
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_schools_district on schools (district);
create index idx_schools_state_city on schools (state, city);
create unique index idx_schools_source_dedupe on schools (source, source_id);

-- ============================================================
-- RATING CATEGORIES
-- Standard categories, seeded once. Keeping this as a table
-- (rather than hardcoding) means you can add a category later
-- without a migration touching the reviews table.
-- ============================================================
create table rating_categories (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,   -- e.g. 'academics', 'safety'
  label text not null,        -- e.g. 'Academics', 'Safety'
  sort_order int not null default 0
);

insert into rating_categories (key, label, sort_order) values
  ('academics', 'Academics', 1),
  ('safety', 'Safety', 2),
  ('teachers', 'Teachers', 3),
  ('facilities', 'Facilities', 4),
  ('communication', 'Communication', 5),
  ('extracurriculars', 'Extracurriculars', 6);

-- ============================================================
-- USER PROFILES
-- Supabase Auth already provides auth.users (email, password,
-- session handling). This table extends it with app-specific
-- fields and role type.
-- ============================================================
create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  role text not null default 'parent',   -- 'parent', 'student', 'guardian'
  created_at timestamptz not null default now()
);

-- ============================================================
-- ADMIN ROLES
-- Separate from profiles.role so moderator access can be
-- granted/revoked independently of account type.
-- ============================================================
create table admin_roles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users (id)
);

-- ============================================================
-- REVIEWS
-- One review per (school, user) — a parent leaves one review
-- per school, editable, rather than unlimited repeat reviews.
-- ============================================================
create table reviews (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  comment text,
  status text not null default 'published',  -- 'published', 'flagged', 'removed'
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (school_id, user_id)
);

create index idx_reviews_school on reviews (school_id);
create index idx_reviews_status on reviews (status);

-- ============================================================
-- REVIEW RATINGS
-- One row per category per review, so each review can carry
-- a distinct star value for academics, safety, etc.
-- ============================================================
create table review_ratings (
  review_id uuid not null references reviews (id) on delete cascade,
  category_id uuid not null references rating_categories (id) on delete cascade,
  stars smallint not null check (stars between 1 and 5),
  primary key (review_id, category_id)
);

-- ============================================================
-- REVIEW PHOTOS
-- Actual image files live in Supabase Storage; this table just
-- tracks metadata and links back to the review.
-- ============================================================
create table review_photos (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references reviews (id) on delete cascade,
  storage_path text not null,   -- path within the Supabase Storage bucket
  created_at timestamptz not null default now()
);

-- ============================================================
-- REVIEW FLAGS
-- Tracks reports from users, feeding the moderation queue.
-- ============================================================
create table review_flags (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references reviews (id) on delete cascade,
  flagged_by uuid references auth.users (id),
  reason text,
  status text not null default 'pending',  -- 'pending', 'reviewed', 'dismissed'
  created_at timestamptz not null default now()
);

create index idx_flags_status on review_flags (status);

-- ============================================================
-- SCHOOL AGGREGATE SCORES (view, not a stored table)
-- Recomputes on read — fine at this scale; can be swapped for
-- a materialized view later if performance requires it.
-- ============================================================
create view school_category_averages as
select
  r.school_id,
  rc.key as category_key,
  rc.label as category_label,
  avg(rr.stars)::numeric(3,2) as avg_stars,
  count(rr.stars) as num_ratings
from reviews r
join review_ratings rr on rr.review_id = r.id
join rating_categories rc on rc.id = rr.category_id
where r.status = 'published'
group by r.school_id, rc.key, rc.label;

create view school_overall_averages as
select
  school_id,
  avg(avg_stars)::numeric(3,2) as overall_avg_stars,
  sum(num_ratings) as total_ratings
from school_category_averages
group by school_id;

-- ============================================================
-- ROW LEVEL SECURITY
-- Enable RLS and lock down write access; adjust policies as
-- auth flow is finalized in Phase 2.
-- ============================================================
alter table schools enable row level security;
alter table reviews enable row level security;
alter table review_ratings enable row level security;
alter table review_flags enable row level security;
alter table profiles enable row level security;

-- Public can read schools and published reviews
create policy "schools are publicly readable" on schools
  for select using (true);

create policy "published reviews are publicly readable" on reviews
  for select using (status = 'published');

-- Authenticated users can insert their own review
create policy "users can insert their own review" on reviews
  for insert with check (auth.uid() = user_id);

create policy "users can update their own review" on reviews
  for update using (auth.uid() = user_id);

-- Authenticated users can flag reviews
create policy "authenticated users can flag reviews" on review_flags
  for insert with check (auth.uid() is not null);
