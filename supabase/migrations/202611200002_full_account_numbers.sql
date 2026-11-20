-- Assign permanent 12-digit app account identifiers while preserving each existing last-four suffix.
alter table public.accounts add column if not exists account_number_full text;

do $$
declare
  a record;
  v_suffix text;
  v_prefix text;
  v_full text;
begin
  for a in select id, account_number_last4 from public.accounts where account_number_full is null or btrim(account_number_full) = '' loop
    v_suffix := right(lpad(regexp_replace(coalesce(a.account_number_last4::text, ''), '[^0-9]', '', 'g'), 4, '0'), 4);
    loop
      v_prefix := lpad(floor(random() * 100000000)::bigint::text, 8, '0');
      v_full := v_prefix || v_suffix;
      exit when not exists (select 1 from public.accounts where account_number_full = v_full);
    end loop;
    update public.accounts set account_number_full = v_full where id = a.id;
  end loop;
end $$;

create unique index if not exists accounts_account_number_full_uidx
  on public.accounts (account_number_full);

create or replace function public.assign_full_account_number()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_suffix text;
  v_prefix text;
  v_full text;
begin
  if new.account_number_full is null or btrim(new.account_number_full) = '' then
    v_suffix := right(lpad(regexp_replace(coalesce(new.account_number_last4::text, ''), '[^0-9]', '', 'g'), 4, '0'), 4);
    loop
      v_prefix := lpad(floor(random() * 100000000)::bigint::text, 8, '0');
      v_full := v_prefix || v_suffix;
      exit when not exists (select 1 from public.accounts where account_number_full = v_full);
    end loop;
    new.account_number_full := v_full;
  end if;
  return new;
end;
$$;

drop trigger if exists accounts_assign_full_account_number on public.accounts;
create trigger accounts_assign_full_account_number
before insert on public.accounts
for each row execute function public.assign_full_account_number();

comment on column public.accounts.account_number_full is 'Permanent unique 12-digit internal account identifier for this app; not a bank-issued account number.';
