begin;
-- Restore access only to battles that were already active and never marked closed.
-- Explicitly closed/disabled battles are left for the administrator to reopen.
update public.quest_limits q
set recruitment_closed=true, raid_entry_enabled=true
from public.raid_battles b
where b.quest_id=q.quest_id
  and b.state='active'
  and q.active
  and q.category='raid'
  and not q.recruitment_closed
returning q.quest_id,q.recruitment_closed,q.raid_entry_enabled;
commit;
