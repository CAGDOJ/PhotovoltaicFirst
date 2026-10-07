-- Edital Vertical - esquema Supabase
create extension if not exists pgcrypto;

create table if not exists public.editais (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  file_hash text not null,
  file_name text,
  exam_name text,
  edital_no text,
  organizer text,
  cargo text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, file_hash, cargo)
);

create table if not exists public.topicos (
  id uuid primary key default gen_random_uuid(),
  edital_id uuid not null references public.editais(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_order integer not null,
  item_number text,
  knowledge text,
  area text not null,
  content text not null,
  status text not null default 'A Estudar' check (status in ('A Estudar','Estudando','Estudado')),
  questions integer not null default 0 check (questions >= 0),
  correct integer not null default 0 check (correct >= 0),
  wrong integer not null default 0 check (wrong >= 0),
  note text,
  updated_at timestamptz not null default now(),
  unique(edital_id, source_order)
);

create table if not exists public.sessoes_questoes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  edital_id uuid not null references public.editais(id) on delete cascade,
  topico_id uuid references public.topicos(id) on delete set null,
  area text not null,
  questions integer not null check (questions > 0),
  correct integer not null check (correct >= 0),
  wrong integer not null check (wrong >= 0),
  accuracy numeric(6,4),
  occurred_at timestamptz not null default now()
);

alter table public.editais enable row level security;
alter table public.topicos enable row level security;
alter table public.sessoes_questoes enable row level security;

drop policy if exists editais_owner_all on public.editais;
create policy editais_owner_all on public.editais
for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists topicos_owner_all on public.topicos;
create policy topicos_owner_all on public.topicos
for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists sessoes_owner_all on public.sessoes_questoes;
create policy sessoes_owner_all on public.sessoes_questoes
for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
