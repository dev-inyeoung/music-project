-- Task 9: reports, auto-hide at 3 reports, operator notification via pg_net.
create extension if not exists pg_net;

create function public.report_entry(p_entry_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_entry public.entries;
  v_inserted int;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_entry from public.entries where id = p_entry_id;
  if not found
     or v_entry.kind <> 'post'
     or v_entry.user_id = v_uid
     or not public.entry_visible_to(v_entry, v_uid) then
    raise exception 'entry_not_found';
  end if;

  insert into public.reports (reporter, entry_id, reason)
  values (v_uid, p_entry_id, public.norm_text(p_reason))
  on conflict (reporter, entry_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    return;
  end if;

  update public.entries
     set report_count = report_count + 1,
         status = case when report_count + 1 >= 3 then 'hidden'::public.entry_status else status end
   where id = p_entry_id;
end $$;

-- Notify the operator. Never blocks a report: any failure is swallowed.
-- Runs AFTER INSERT on reports, before report_entry bumps report_count, so report_count is sent as current+1.
create function public.reports_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_url text;
  v_secret text;
  v_count int;
begin
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'notify_report_url';
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'notify_report_secret';
    if v_url is not null and v_secret is not null then
      select report_count + 1 into v_count from public.entries where id = new.entry_id;
      perform net.http_post(
        url := v_url,
        body := jsonb_build_object('entry_id', new.entry_id, 'reason', new.reason, 'report_count', v_count),
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret)
      );
    end if;
  exception when others then
    raise warning 'reports_notify failed: %', sqlerrm;
  end;
  return null;
end $$;

create trigger reports_notify after insert on public.reports
  for each row execute function public.reports_notify();

revoke execute on function public.report_entry(uuid, text) from public, anon;
grant execute on function public.report_entry(uuid, text) to authenticated;
revoke execute on function public.reports_notify() from public, anon, authenticated;
