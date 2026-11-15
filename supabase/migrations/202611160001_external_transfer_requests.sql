-- External transfer requests are recorded as pending ledger debits only.
-- No external bank payment is initiated by this function.
create table if not exists public.external_transfer_requests (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  from_account_id uuid not null references public.accounts(id),
  amount numeric(18,2) not null check (amount > 0),
  beneficiary_name text not null,
  bank_name text not null,
  account_number text not null,
  routing_number text not null,
  country text not null,
  reference_memo text,
  transfer_date date not null,
  reference_number text not null unique,
  status text not null default 'pending' check (status in ('pending','cancelled','processed')),
  created_at timestamptz not null default now()
);

alter table public.external_transfer_requests enable row level security;
drop policy if exists "Customers can view their own external transfer requests" on public.external_transfer_requests;
create policy "Customers can view their own external transfer requests"
  on public.external_transfer_requests for select
  to authenticated using (owner_id = auth.uid());

revoke all on public.external_transfer_requests from anon, authenticated;
grant select on public.external_transfer_requests to authenticated;

create or replace function public.record_external_transfer_request(
  p_request_id uuid,
  p_from_account uuid,
  p_amount numeric,
  p_beneficiary_name text,
  p_bank_name text,
  p_account_number text,
  p_routing_number text,
  p_country text,
  p_reference_memo text,
  p_transfer_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_account public.accounts%rowtype;
  v_existing public.external_transfer_requests%rowtype;
  v_reference text;
  v_description text;
  v_amount numeric(18,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_request_id is null then raise exception 'Transfer request identifier is required'; end if;
  select * into v_existing from public.external_transfer_requests where id = p_request_id;
  if v_existing.id is not null then
    if v_existing.owner_id <> auth.uid() then raise exception 'Invalid transfer request'; end if;
    return jsonb_build_object('success', true, 'reference_number', v_existing.reference_number,
      'status', v_existing.status, 'amount', v_existing.amount, 'new_balance',
      (select balance from public.accounts where id = v_existing.from_account_id));
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then raise exception 'Enter a valid transfer amount'; end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then raise exception 'Enter a valid transfer amount'; end if;
  if nullif(trim(p_beneficiary_name), '') is null or nullif(trim(p_bank_name), '') is null
    or nullif(trim(p_account_number), '') is null or nullif(trim(p_routing_number), '') is null
    or nullif(trim(p_country), '') is null or p_transfer_date is null then
    raise exception 'Complete all required beneficiary and transfer details';
  end if;
  select * into v_account from public.accounts where id = p_from_account for update;
  if v_account.id is null or v_account.owner_id <> auth.uid() then
    raise exception 'Source account is not owned by the signed-in customer';
  end if;
  if coalesce(v_account.balance, 0) < v_amount then raise exception 'Insufficient available balance'; end if;

  v_reference := 'CITI-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  v_description := 'External transfer request to ' || trim(p_beneficiary_name);
  insert into public.external_transfer_requests
    (id, owner_id, from_account_id, amount, beneficiary_name, bank_name, account_number,
     routing_number, country, reference_memo, transfer_date, reference_number, status)
  values
    (p_request_id, auth.uid(), v_account.id, v_amount, trim(p_beneficiary_name), trim(p_bank_name),
     trim(p_account_number), trim(p_routing_number), trim(p_country),
     nullif(trim(coalesce(p_reference_memo, '')), ''), p_transfer_date, v_reference, 'pending');

  update public.accounts set balance = round(balance - v_amount, 2) where id = v_account.id;
  insert into public.transactions
    (id, owner_id, account_id, transaction_date, description, transaction_type, amount, direction, transaction_details)
  values
    (gen_random_uuid(), auth.uid(), v_account.id, p_transfer_date, v_description,
     'Transfer', v_amount, 'debit', 'Pending external transfer request; funds reserved in Citi platform ledger only');

  return jsonb_build_object('success', true, 'reference_number', v_reference,
    'status', 'pending', 'amount', v_amount, 'new_balance', round(v_account.balance - v_amount, 2));
end;
$$;

revoke all on function public.record_external_transfer_request(uuid, uuid, numeric, text, text, text, text, text, text, date) from public;
grant execute on function public.record_external_transfer_request(uuid, uuid, numeric, text, text, text, text, text, text, date) to authenticated;
