-- OceanHoop Community Directory: database schema, Row Level Security and storage rules.
-- Run once in Supabase: SQL Editor > New query > paste > Run.
create extension if not exists pgcrypto;

create table if not exists administrators (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text, created_at timestamptz not null default now());

create or replace function is_admin() returns boolean
language sql security definer stable set search_path = public as
$$ select exists (select 1 from administrators where user_id = auth.uid()) $$;

-- PUBLIC tables (hold approved records only; no private contact data)
create table if not exists basketball_courts (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 120),
  state text not null, district text not null,
  address text not null check (char_length(address) between 3 and 300),
  map_link text check (map_link is null or map_link ~* '^https://'),
  court_type text not null check (court_type in ('outdoor','covered')),
  access text not null check (access in ('public','private','school','unknown')),
  description text check (char_length(description) <= 1000),
  status text not null default 'approved' check (status in ('approved','hidden')),
  source_submission uuid, created_at timestamptz not null default now());

create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null check (char_length(name) between 2 and 120),
  state text not null, district text not null,
  category text not null check (category in ('School','Private club','Community','Youth','Independent','Other')),
  age_group text not null, player_count int check (player_count between 1 and 100),
  description text check (char_length(description) <= 1500),
  instagram text check (instagram is null or instagram ~* '^https://'),
  facebook text check (facebook is null or facebook ~* '^https://'),
  other_link text check (other_link is null or other_link ~* '^https://'),
  logo_url text, verified boolean not null default false,
  status text not null default 'approved' check (status in ('approved','hidden')),
  source_submission uuid, created_at timestamptz not null default now());

-- PRIVATE queue: every submission lands here first
create table if not exists submissions (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('court','team')),
  status text not null default 'pending' check (status in ('pending','under_review','approved','rejected')),
  payload jsonb not null check (pg_column_size(payload) < 8000),
  private jsonb not null default '{}'::jsonb check (pg_column_size(private) < 4000),
  fingerprint text, admin_notes text, published_id uuid,
  created_at timestamptz not null default now(), reviewed_at timestamptz);

-- Duplicate protection: same kind + name + state + district cannot be queued twice
create unique index if not exists submissions_no_dupes on submissions (kind, fingerprint)
  where status in ('pending','under_review','approved');

create or replace function submissions_guard() returns trigger language plpgsql as $$
begin
  new.fingerprint := lower(regexp_replace(coalesce(new.payload->>'name','')||'|'||coalesce(new.payload->>'state','')||'|'||coalesce(new.payload->>'district',''),'[^a-zA-Z0-9|]','','g'));
  if (select count(*) from submissions where created_at > now() - interval '10 minutes') > 60 then
    raise exception 'Too many submissions right now. Please try again later.'; end if;
  if new.private ? 'contact_email' and
     (select count(*) from submissions where private->>'contact_email' = new.private->>'contact_email' and created_at > now() - interval '1 day') >= 3 then
    raise exception 'Daily submission limit reached for this email.'; end if;
  return new;
end $$;
drop trigger if exists submissions_guard_t on submissions;
create trigger submissions_guard_t before insert on submissions for each row execute function submissions_guard();

-- Approval: copies ONLY public fields into the public tables (admin only)
create or replace function approve_submission(sub_id uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare s submissions; p jsonb; nid uuid;
begin
  if not is_admin() then raise exception 'not authorised'; end if;
  select * into s from submissions where id = sub_id for update;
  if s.id is null then raise exception 'not found'; end if;
  if s.status = 'approved' then return s.published_id; end if;
  p := s.payload;
  if s.kind = 'team' then
    insert into teams(slug,name,state,district,category,age_group,player_count,description,instagram,facebook,other_link,logo_url,source_submission)
    values (trim(both '-' from lower(regexp_replace(p->>'name','[^a-zA-Z0-9]+','-','g')))||'-'||substr(s.id::text,1,6),
      p->>'name',p->>'state',p->>'district',p->>'category',p->>'age_group',nullif(p->>'player_count','')::int,
      p->>'description',nullif(p->>'instagram',''),nullif(p->>'facebook',''),nullif(p->>'other_link',''),nullif(p->>'logo_url',''),s.id)
    returning id into nid;
  else
    insert into basketball_courts(name,state,district,address,map_link,court_type,access,description,source_submission)
    values (p->>'name',p->>'state',p->>'district',p->>'address',nullif(p->>'map_link',''),p->>'court_type',p->>'access',
      p->>'description',s.id) returning id into nid;
  end if;
  update submissions set status='approved', reviewed_at=now(), published_id=nid where id = sub_id;
  return nid;
end $$;
revoke all on function approve_submission(uuid) from public, anon;
grant execute on function approve_submission(uuid) to authenticated;

-- ROW LEVEL SECURITY
alter table administrators enable row level security;
alter table basketball_courts enable row level security;
alter table teams enable row level security;
alter table submissions enable row level security;

create policy "admin sees self" on administrators for select to authenticated using (user_id = auth.uid());
create policy "public reads approved courts" on basketball_courts for select to anon, authenticated using (status = 'approved');
create policy "public reads approved teams" on teams for select to anon, authenticated using (status = 'approved');
create policy "admin manages courts" on basketball_courts for all to authenticated using (is_admin()) with check (is_admin());
create policy "admin manages teams" on teams for all to authenticated using (is_admin()) with check (is_admin());
-- Visitors may only INSERT a pending submission. They can never read, edit or delete any.
create policy "anyone can submit pending" on submissions for insert to anon, authenticated
  with check (status = 'pending' and admin_notes is null and reviewed_at is null and published_id is null);
create policy "admin manages submissions" on submissions for all to authenticated using (is_admin()) with check (is_admin());

-- STORAGE: private bucket for uploads (evidence, original photos), public bucket for approved logos/photos
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('submission-files','submission-files', false, 3145728, array['image/jpeg','image/png','image/webp']),
  ('public-media','public-media', true, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "anyone uploads to private bucket" on storage.objects for insert to anon, authenticated with check (bucket_id = 'submission-files');
create policy "admin reads private bucket" on storage.objects for select to authenticated using (bucket_id = 'submission-files' and is_admin());
create policy "admin deletes private bucket" on storage.objects for delete to authenticated using (bucket_id = 'submission-files' and is_admin());
create policy "admin writes public media" on storage.objects for all to authenticated using (bucket_id = 'public-media' and is_admin()) with check (bucket_id = 'public-media' and is_admin());
