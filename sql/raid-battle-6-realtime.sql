begin;
-- Only the battle revision row is streamed. Logs, actions and profiles stay RPC-only.
do $$
begin
  if not exists(select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='raid_battles') then
    alter publication supabase_realtime add table public.raid_battles;
  end if;
end;
$$;
notify pgrst,'reload schema';
commit;
