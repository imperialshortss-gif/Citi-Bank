-- Assign each Citi account a permanent 14-digit account number.
-- The final four digits always match the existing account_number_last4 value.
alter table public.accounts
  add column if not exists account_number_full text;

create or replace function public.generate_citi_account_number(p_last4 text, p_exclude_id uuid default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last4 text := right(regexp_replace(coalesce(p_last4, ''), '\\D', '', 'g'), 4);
  v_candidate text;
  v_attempt integer := 0;
begin
  if length(v_last4) <> 4 then
    raise exception 'Account must have exactly four ending digits';
  end if;

  loop
    v_attempt := v_attempt + 1;
    v_candidate := lpad(floor(random() * 10000000000)::bigint::text, 10, '0') || v_last4;
    exit when not exists (
      select 1 from public.accounts a
      where a.account_number_full = v_candidate
        and (p_exclude_id is null or a.id <> p_exclude_id)
    );
    if v_attempt >= 100 then
      raise exception 'Unable to generate a unique Citi account number';
    end if;
  end loop;

  return v_candidate;
end;
$$;

create or replace function public.set_citi_full_account_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.account_number_full is null
     or new.account_number_full = ''
     or (tg_op = 'UPDATE' and new.account_number_last4 is distinct from old.account_number_last4) then
    new.account_number_full := public.generate_citi_account_number(new.account_number_last4, new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists accounts_set_citi_full_account_number on public.accounts;
create trigger accounts_set_citi_full_account_number
before insert or update of account_number_last4, account_number_full
on public.accounts
for each row execute function public.set_citi_full_account_number();

-- Backfill all existing accounts without changing their current last-four display.
update public.accounts
set account_number_full = public.generate_citi_account_number(account_number_last4, id)
where account_number_full is null or account_number_full = '';

create unique index if not exists accounts_account_number_full_unique
  on public.accounts (account_number_full);

alter table public.accounts
  alter column account_number_full set not null;

comment on column public.accounts.account_number_full is
  'Permanent 14-digit Citi account identifier; final four digits match account_number_last4. Admin-only display.';
