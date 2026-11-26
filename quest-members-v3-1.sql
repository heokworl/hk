begin;

alter table public.guild_profiles
 add column if not exists hp integer not null default 200 check(hp between 0 and 200),
 add column if not exists mp integer not null default 200 check(mp between 0 and 200);
alter table public.quest_limits
 add column if not exists category text not null default 'daily' check(category in ('daily','raid','event')),
 add column if not exists game_version integer not null default 1 check(game_version>0);
update public.quest_limits set category='raid' where quest_id='quarantine_clear';
create table if not exists public.quest_entry_blocks(
 user_id uuid not null references auth.users(id) on delete cascade,
 quest_key text not null default '*',
 blocked_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 primary key(user_id,quest_key)
);
alter table public.quest_entry_blocks enable row level security;
revoke all on public.quest_entry_blocks from anon,authenticated;
alter table public.shop_item_uses
 add column if not exists target_user_id uuid references auth.users(id) on delete set null;
create or replace function public.get_member_stats_v3()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('hp',p.hp,'mp',p.mp,'max_hp',200,'max_mp',200)
 from public.guild_profiles p where p.user_id=auth.uid();
$$;
create or replace function public.get_item_targets_v3()
returns table(user_id uuid,username text)
language sql stable security definer set search_path='' as $$
 select p.user_id,p.username from public.guild_profiles p
 where auth.uid() is not null and (
 exists(select 1 from public.quest_admins a where a.user_id=auth.uid())
 or not exists(select 1 from public.quest_admins a where a.user_id=p.user_id))
 order by p.username_key;
$$;
create or replace function public.get_quest_details_v3()
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object(
 'quest_id',q.quest_id,'category',q.category,'game_version',q.game_version,
 'blocked',exists(select 1 from public.quest_entry_blocks b where b.user_id=auth.uid() and b.quest_key in ('*',q.quest_id)),
 'participants',coalesce((select jsonb_agg(p.username order by e.joined_at)
 from public.quest_participants e join public.guild_profiles p on p.user_id=e.user_id
 where e.quest_id=q.quest_id),'[]'::jsonb)
 )),'[]'::jsonb) from public.quest_limits q where q.active and auth.uid() is not null;
$$;
revoke all on function public.get_member_stats_v3() from public;
grant execute on function public.get_member_stats_v3() to authenticated;
revoke all on function public.get_item_targets_v3() from public;
grant execute on function public.get_item_targets_v3() to authenticated;
revoke all on function public.get_quest_details_v3() from public;
grant execute on function public.get_quest_details_v3() to authenticated;

notify pgrst,'reload schema';
commit;
