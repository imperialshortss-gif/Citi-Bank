-- Internal account-ledger transfers. All balance changes are atomic and authorized by the signed-in account owner.
create or replace function public.list_transfer_recipients()
returns table (
  account_id uuid,
  account_name text,
  account_type text,
  account_number_last4 text,
  owner_name text
)
language sql
security definer
set search_path = public, auth
as $$
  select a.id, a.name, a.account_type, a.account_number_last4,
         coalesce(u.raw_user_meta_data->>'fullName', u.raw_user_meta_data->>'username', 'Customer') as owner_name
  from public.accounts a
  join auth.users u on u.id = a.owner_id
  where auth.uid() is not null
    and a.owner_id <> auth.uid()
    and u.email like '%@citi-login.example.com'
  order by owner_name, a.name;
$$;

revoke all on function public.list_transfer_recipients() from public;
grant execute on function public.list_transfer_recipients() to authenticated;

create or replace function public.record_internal_transfer(
  p_from_account uuid,
  p_to_account uuid,
  p_amount numeric,
  p_description text,
  p_transfer_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_from public.accounts%rowtype;
  v_to public.accounts%rowtype;
  v_description text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if p_from_account is null or p_to_account is null or p_from_account = p_to_account then
    raise exception 'Choose two different accounts';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000000 then
    raise exception 'Enter a valid transfer amount';
  end if;
  if p_transfer_date is null then
    raise exception 'Choose a transfer date';
  end if;

  -- Lock both rows in a stable order to avoid concurrent balance races.
  perform 1
  from public.accounts
  where id in (p_from_account, p_to_account)
  order by id
  for update;

  select * into v_from from public.accounts where id = p_from_account;
  select * into v_to from public.accounts where id = p_to_account;

  if v_from.id is null or v_from.owner_id <> auth.uid() then
    raise exception 'Source account is not owned by the signed-in customer';
  end if;
  if v_to.id is null or v_to.owner_id = auth.uid() then
    raise exception 'Choose an account belonging to another customer';
  end if;
  if coalesce(v_from.balance, 0) < p_amount then
    raise exception 'Insufficient available balance';
  end if;

  v_description := coalesce(nullif(trim(p_description), ''), 'Account transfer');
  update public.accounts set balance = round(balance - p_amount, 2) where id = v_from.id;
  update public.accounts set balance = round(balance + p_amount, 2) where id = v_to.id;

  insert into public.transactions
    (id, owner_id, account_id, transaction_date, description, transaction_type, amount, direction, transaction_details)
  values
    (gen_random_uuid(), v_from.owner_id, v_from.id, p_transfer_date, v_description || ' — to ' || v_to.name, 'Transfer', p_amount, 'debit', 'Internal account ledger transfer'),
    (gen_random_uuid(), v_to.owner_id, v_to.id, p_transfer_date, v_description || ' — from ' || v_from.name, 'Transfer', p_amount, 'credit', 'Internal account ledger transfer');

  return jsonb_build_object(
    'success', true,
    'from_balance', round(v_from.balance - p_amount, 2),
    'to_balance', round(v_to.balance + p_amount, 2)
  );
end;
$$;

revoke all on function public.record_internal_transfer(uuid, uuid, numeric, text, date) from public;
grant execute on function public.record_internal_transfer(uuid, uuid, numeric, text, date) to authenticated;
