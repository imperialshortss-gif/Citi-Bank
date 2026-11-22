-- Admin-only, auditable reversals for app-recorded transfers.
alter table public.transactions
  add column if not exists status text not null default 'posted',
  add column if not exists reversal_of uuid,
  add column if not exists reversal_reason text;
alter table public.external_transfer_requests
  drop constraint if exists external_transfer_requests_status_check;
alter table public.external_transfer_requests
  add constraint external_transfer_requests_status_check
  check (status in ('pending','cancelled','processed','reversed'));
alter table public.external_transfer_requests
  add column if not exists reversed_at timestamptz,
  add column if not exists reversed_by uuid references auth.users(id),
  add column if not exists reversal_reason text;


-- New external request debit rows must display as pending immediately.
create or replace function public.mark_pending_external_transfer_ledger_row()
returns trigger language plpgsql security definer set search_path=public as $
begin
  if new.transaction_details like 'Pending external transfer request%'
     and exists(select 1 from public.external_transfer_requests e
       where e.owner_id=new.owner_id and e.from_account_id=new.account_id
         and e.amount=new.amount and e.transfer_date=new.transaction_date
         and e.status='pending'
         and new.description='External transfer request to '||e.beneficiary_name) then
    new.status:='pending';
  end if;
  return new;
end;
$;
drop trigger if exists mark_pending_external_transfer_ledger_row on public.transactions;
create trigger mark_pending_external_transfer_ledger_row before insert on public.transactions
for each row execute function public.mark_pending_external_transfer_ledger_row();

-- Identify pending external request ledger rows for status display.
update public.transactions t
set status='pending'
where t.transaction_type='Transfer'
  and t.transaction_details like 'Pending external transfer request%'
  and exists (
    select 1 from public.external_transfer_requests e
    where e.owner_id=t.owner_id and e.from_account_id=t.account_id
      and e.amount=t.amount and e.transfer_date=t.transaction_date
      and e.status='pending'
      and t.description='External transfer request to '||e.beneficiary_name
  );


create or replace function public.admin_list_transfer_transactions()
returns table(
  id uuid, transaction_date date, description text, transaction_type text,
  account_id uuid, account_name text, owner_name text, amount numeric,
  direction text, status text, transaction_details text, reversal_of uuid
)
language plpgsql
security definer
set search_path = public, auth
as $
begin
  if auth.uid() is null or not exists(
    select 1 from auth.users where id=auth.uid() and email='admin@citi-login.example.com'
  ) then raise exception 'Administrator access required'; end if;
  return query
  select t.id,t.transaction_date,t.description,t.transaction_type,t.account_id,a.name,
    coalesce(u.raw_user_meta_data->>'fullName',u.raw_user_meta_data->>'username','Customer'),
    t.amount,t.direction,coalesce(t.status,'posted'),t.transaction_details,t.reversal_of
  from public.transactions t
  join public.accounts a on a.id=t.account_id
  join auth.users u on u.id=t.owner_id
  where t.transaction_type='Transfer'
  order by t.transaction_date desc,t.id desc;
end;
$;
revoke all on function public.admin_list_transfer_transactions() from public;
grant execute on function public.admin_list_transfer_transactions() to authenticated;

create or replace function public.admin_reverse_transfer(p_transaction_id uuid,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_tx public.transactions%rowtype;
  v_peer public.transactions%rowtype;
  v_req public.external_transfer_requests%rowtype;
  v_sender public.accounts%rowtype;
  v_receiver public.accounts%rowtype;
  v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_reversal_id uuid;
  v_base text;
begin
  if auth.uid() is null or not exists (
    select 1 from auth.users where id=auth.uid() and email='admin@citi-login.example.com'
  ) then raise exception 'Administrator access required'; end if;
  if v_reason is null then raise exception 'Enter a reversal reason'; end if;

  select * into v_tx from public.transactions where id=p_transaction_id for update;
  if v_tx.id is null then raise exception 'Transaction not found'; end if;
  if v_tx.transaction_type<>'Transfer' then raise exception 'Only transfer transactions can be reversed'; end if;
  if v_tx.status='reversed' then raise exception 'This transfer has already been reversed'; end if;

  if v_tx.transaction_details like 'Pending external transfer request%' then
    select * into v_req from public.external_transfer_requests
    where owner_id=v_tx.owner_id and from_account_id=v_tx.account_id
      and amount=v_tx.amount and transfer_date=v_tx.transaction_date
      and status='pending'
      and 'External transfer request to '||beneficiary_name=v_tx.description
    order by created_at desc limit 1 for update;
    if v_req.id is null then raise exception 'Only pending external transfer requests can be reversed'; end if;
    select * into v_sender from public.accounts where id=v_req.from_account_id for update;
    update public.accounts set balance=round(balance+v_req.amount,2) where id=v_sender.id;
    update public.transactions set status='reversed',reversal_reason=v_reason
      where id=v_tx.id;
    v_reversal_id:=gen_random_uuid();
    insert into public.transactions
      (id,owner_id,account_id,transaction_date,description,transaction_type,amount,direction,transaction_details,status,reversal_of,reversal_reason)
    values(v_reversal_id,v_req.owner_id,v_req.from_account_id,current_date,
      'Reversal — external transfer to '||v_req.beneficiary_name,'Transfer',v_req.amount,
      'credit','Reversal of reference '||v_req.reference_number,'posted',v_tx.id,v_reason);
    update public.external_transfer_requests set status='reversed',reversed_at=now(),
      reversed_by=auth.uid(),reversal_reason=v_reason where id=v_req.id;
    return jsonb_build_object('success',true,'type','external','reversal_transaction_id',v_reversal_id);
  end if;

  if v_tx.transaction_details<>'Internal account ledger transfer' then
    raise exception 'This transfer is not eligible for reversal';
  end if;
  v_base:=split_part(v_tx.description,' — ',1);
  if v_tx.direction='debit' then
    select * into v_peer from public.transactions p
    where p.transaction_type='Transfer' and p.direction='credit'
      and p.transaction_date=v_tx.transaction_date and p.amount=v_tx.amount
      and p.transaction_details='Internal account ledger transfer'
      and p.description=v_base||' — from '||(select name from public.accounts where id=v_tx.account_id)
    order by p.id limit 1 for update;
  else
    select * into v_peer from public.transactions p
    where p.transaction_type='Transfer' and p.direction='debit'
      and p.transaction_date=v_tx.transaction_date and p.amount=v_tx.amount
      and p.transaction_details='Internal account ledger transfer'
      and p.description=v_base||' — to '||(select name from public.accounts where id=v_tx.account_id)
    order by p.id limit 1 for update;
  end if;
  if v_peer.id is null then raise exception 'The matching internal transfer entry could not be found'; end if;
  if v_peer.status='reversed' then raise exception 'This transfer has already been reversed'; end if;

  if v_tx.direction='debit' then
    select * into v_sender from public.accounts where id=v_tx.account_id;
    select * into v_receiver from public.accounts where id=v_peer.account_id;
  else
    select * into v_sender from public.accounts where id=v_peer.account_id;
    select * into v_receiver from public.accounts where id=v_tx.account_id;
  end if;
  perform 1 from public.accounts where id in (v_sender.id,v_receiver.id) order by id for update;
  select * into v_sender from public.accounts where id=v_sender.id;
  select * into v_receiver from public.accounts where id=v_receiver.id;
  if coalesce(v_receiver.balance,0)<v_tx.amount then
    raise exception 'The recipient account has insufficient balance for this reversal';
  end if;
  update public.accounts set balance=round(balance+v_tx.amount,2) where id=v_sender.id;
  update public.accounts set balance=round(balance-v_tx.amount,2) where id=v_receiver.id;
  update public.transactions set status='reversed',reversal_reason=v_reason where id in (v_tx.id,v_peer.id);

  insert into public.transactions
    (id,owner_id,account_id,transaction_date,description,transaction_type,amount,direction,transaction_details,status,reversal_of,reversal_reason)
  values
    (gen_random_uuid(),v_sender.owner_id,v_sender.id,current_date,'Reversal — internal transfer','Transfer',v_tx.amount,'credit','Reversal of internal transfer','posted',case when v_tx.direction='debit' then v_tx.id else v_peer.id end,v_reason),
    (gen_random_uuid(),v_receiver.owner_id,v_receiver.id,current_date,'Reversal — internal transfer','Transfer',v_tx.amount,'debit','Reversal of internal transfer','posted',case when v_tx.direction='credit' then v_tx.id else v_peer.id end,v_reason);
  return jsonb_build_object('success',true,'type','internal');
end;
$$;
revoke all on function public.admin_reverse_transfer(uuid,text) from public;
grant execute on function public.admin_reverse_transfer(uuid,text) to authenticated;
