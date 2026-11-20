-- Resolve one internal-transfer beneficiary by exact full account number.
-- Only the beneficiary name and account label are returned; no customer list is exposed.
create or replace function public.lookup_transfer_recipient(p_account_number_full text)
returns table (
  account_id uuid,
  beneficiary_name text,
  account_name text
)
language sql
security definer
set search_path = public, auth
as $$
  select
    a.id,
    coalesce(
      nullif(trim(u.raw_user_meta_data->>'fullName'), ''),
      nullif(trim(u.raw_user_meta_data->>'username'), ''),
      'Customer'
    ) as beneficiary_name,
    a.name as account_name
  from public.accounts a
  join auth.users u on u.id = a.owner_id
  where auth.uid() is not null
    and p_account_number_full ~ '^[0-9]{12}$'
    and a.account_number_full = p_account_number_full
    and a.owner_id <> auth.uid()
    and u.email like '%@citi-login.example.com'
    and u.email <> 'admin@citi-login.example.com'
  limit 1;
$$;

revoke all on function public.lookup_transfer_recipient(text) from public;
grant execute on function public.lookup_transfer_recipient(text) to authenticated;
