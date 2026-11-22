-- Include the administrator's reversal explanation in transfer-history results.
-- The return type is extended, so recreate the no-argument RPC.
drop function if exists public.admin_list_transfer_transactions();

create function public.admin_list_transfer_transactions()
returns table(
  id uuid,
  transaction_date date,
  description text,
  transaction_type text,
  account_id uuid,
  account_name text,
  owner_name text,
  amount numeric,
  direction text,
  status text,
  transaction_details text,
  reversal_of uuid,
  reversal_reason text
)
language plpgsql
security definer
set search_path = public, auth
as $fn$
begin
  if auth.uid() is null or not exists(
    select 1
    from auth.users as admin_user
    where admin_user.id = auth.uid()
      and admin_user.email = 'admin@citi-login.example.com'
  ) then
    raise exception 'Administrator access required';
  end if;

  return query
  select
    t.id,
    t.transaction_date,
    t.description,
    t.transaction_type,
    t.account_id,
    a.name,
    coalesce(
      customer.raw_user_meta_data->>'fullName',
      customer.raw_user_meta_data->>'username',
      'Customer'
    ),
    t.amount,
    t.direction,
    coalesce(t.status, 'posted'),
    t.transaction_details,
    t.reversal_of,
    t.reversal_reason
  from public.transactions as t
  join public.accounts as a on a.id = t.account_id
  join auth.users as customer on customer.id = t.owner_id
  where t.transaction_type = 'Transfer'
  order by t.transaction_date desc, t.id desc;
end;
$fn$;

revoke all on function public.admin_list_transfer_transactions() from public;
grant execute on function public.admin_list_transfer_transactions() to authenticated;
