-- Run this in Supabase SQL Editor for project ywqesktuqvgsmrgraors

-- Table to store each check result
create table if not exists uptime_checks (
  id uuid primary key default gen_random_uuid(),
  service text not null,
  status text not null check (status in ('up', 'down', 'degraded')),
  error_rate numeric,
  total_invocations int,
  checked_at timestamptz not null default now()
);

create index idx_uptime_checks_service_time
  on uptime_checks (service, checked_at desc);

-- RPC: get hourly aggregated data
-- correct = up or degraded, incorrect = down
-- hour_status: 9-12 correct = up, 5-8 = degraded, 0-4 = down
create or replace function get_uptime_hourly(hours_back int default 24)
returns table (
  service text,
  hour timestamptz,
  hour_status text,
  total_checks bigint,
  correct_checks bigint
)
language sql stable
as $$
  select
    uc.service,
    date_trunc('hour', uc.checked_at) as hour,
    case
      when count(*) filter (where uc.status in ('up', 'degraded')) >= 9 then 'up'
      when count(*) filter (where uc.status in ('up', 'degraded')) >= 5 then 'degraded'
      else 'down'
    end as hour_status,
    count(*) as total_checks,
    count(*) filter (where uc.status in ('up', 'degraded')) as correct_checks
  from uptime_checks uc
  where uc.checked_at >= now() - make_interval(hours => hours_back)
  group by uc.service, date_trunc('hour', uc.checked_at)
  order by uc.service, hour;
$$;

-- RPC: get current status per service (latest check)
create or replace function get_current_status()
returns table (
  service text,
  status text,
  error_rate numeric,
  checked_at timestamptz
)
language sql stable
as $$
  select distinct on (uc.service)
    uc.service,
    uc.status,
    uc.error_rate,
    uc.checked_at
  from uptime_checks uc
  order by uc.service, uc.checked_at desc;
$$;

-- RPC: get recent incidents (down checks only)
create or replace function get_recent_incidents(days_back int default 7)
returns table (
  service text,
  status text,
  checked_at timestamptz
)
language sql stable
as $$
  select uc.service, uc.status, uc.checked_at
  from uptime_checks uc
  where uc.checked_at >= now() - make_interval(days => days_back)
    and uc.status = 'down'
  order by uc.checked_at desc;
$$;

-- RLS: anonymous reads, service role inserts
alter table uptime_checks enable row level security;

create policy "Allow anonymous read" on uptime_checks
  for select using (true);

create policy "Allow service role insert" on uptime_checks
  for insert with check (true);
