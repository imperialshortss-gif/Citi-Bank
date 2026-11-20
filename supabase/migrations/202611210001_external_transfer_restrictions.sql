-- Per-account external transfer availability controls.
alter table public.accounts
  add column if not exists external_transfer_blocked boolean not null default false,
  add column if not exists external_transfer_message text not null default '';

comment on column public.accounts.external_transfer_blocked is 'Whether external transfer requests are disabled for this account in this app.';
comment on column public.accounts.external_transfer_message is 'Administrator-authored message displayed when external transfers are unavailable for this account.';

-- Customer-facing pre-check; only the owner of the source account can read its setting.
create or replace function public.check_external_transfer_restriction(p_account_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_account public.accounts%rowtype;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_account
  from public.accounts
  where id = p_account_id and owner_id = auth.uid();
  if v_account.id is null then raise exception 'Source account was not found'; end if;
  return jsonb_build_object(
    'blocked', coalesce(v_account.external_transfer_blocked, false),
    'message', coalesce(v_account.external_transfer_message, '')
  );
end;
$$;

revoke all on function public.check_external_transfer_restriction(uuid) from public;
grant execute on function public.check_external_transfer_restriction(uuid) to authenticated;

-- Enforce the restriction inside the database transaction as well. The existing
-- record_external_transfer_request function inserts into this table before
-- debiting the source account, so a rejected insert rolls back without a debit.
create or replace function public.enforce_external_transfer_availability()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_blocked boolean;
  v_message text;
begin
  select coalesce(external_transfer_blocked, false),
         coalesce(external_transfer_message, '')
    into v_blocked, v_message
  from public.accounts
  where id = new.from_account_id;

  if v_blocked then
    raise exception using
      message = coalesce(nullif(trim(v_message), ''), 'External transfers are currently unavailable for this account.');
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_external_transfer_availability on public.external_transfer_requests;
create trigger enforce_external_transfer_availability
before insert on public.external_transfer_requests
for each row execute function public.enforce_external_transfer_availability();
