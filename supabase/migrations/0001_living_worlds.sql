-- Living Worlds remote schema (§7): append-only event log + projections
-- support. All tables namespaced by `scope` (one world / test-run each).

create extension if not exists vector;

-- Source of truth: the append-only event log (§1.1).
create table if not exists lw_events (
  scope            text        not null,
  seq              integer     not null,
  event_id         text        not null,
  world_id         text        not null,
  timeline         text        not null,
  subjective_clock integer     not null default 0,
  type             text        not null,
  payload          jsonb       not null default '{}',
  cause            jsonb       not null default '{}',
  created_at       timestamptz not null default now(),
  primary key (scope, seq)
);

-- Events are immutable: block UPDATE and DELETE at the database level.
create or replace function lw_events_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'lw_events is append-only (undo uses revert markers)';
end $$;

drop trigger if exists lw_events_no_update on lw_events;
create trigger lw_events_no_update
  before update or delete on lw_events
  for each row execute function lw_events_immutable();

-- Soft undo (§1.1): marker table, never deletions.
create table if not exists lw_revert_markers (
  scope text    not null,
  seq   integer not null,
  primary key (scope, seq)
);

-- Wiki embeddings (pgvector). 64 dims matches the fixture embedder; swap to
-- 1536 when pointing at a real embedding model.
create table if not exists lw_embeddings (
  scope     text not null,
  entry_id  text not null,
  embedding vector(64) not null,
  primary key (scope, entry_id)
);

-- Semantic top-k via pgvector `<->` (§5.3).
create or replace function lw_match_wiki(p_scope text, p_query vector(64),
                                         p_k int)
returns table (entry_id text, distance float)
language sql stable as $$
  select e.entry_id, e.embedding <-> p_query as distance
  from lw_embeddings e
  where e.scope = p_scope
  order by e.embedding <-> p_query
  limit p_k;
$$;

-- Cloud saves bucket (§7, §8).
insert into storage.buckets (id, name, public)
values ('world-saves', 'world-saves', false)
on conflict (id) do nothing;

-- Dev RLS: permissive for anon while the game has no auth story yet.
-- Tighten to per-user policies when accounts land.
alter table lw_events enable row level security;
alter table lw_revert_markers enable row level security;
alter table lw_embeddings enable row level security;

drop policy if exists lw_events_all on lw_events;
create policy lw_events_all on lw_events
  for all using (true) with check (true);
drop policy if exists lw_revert_markers_all on lw_revert_markers;
create policy lw_revert_markers_all on lw_revert_markers
  for all using (true) with check (true);
drop policy if exists lw_embeddings_all on lw_embeddings;
create policy lw_embeddings_all on lw_embeddings
  for all using (true) with check (true);

drop policy if exists lw_saves_all on storage.objects;
create policy lw_saves_all on storage.objects
  for all using (bucket_id = 'world-saves')
  with check (bucket_id = 'world-saves');
