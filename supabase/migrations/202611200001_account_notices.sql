alter table public.accounts
  add column if not exists notice_message text not null default '',
  add column if not exists notice_enabled boolean not null default false;

comment on column public.accounts.notice_message is 'Administrator-authored notice displayed on the owning customer dashboard.';
comment on column public.accounts.notice_enabled is 'Whether the account notice is currently displayed on the owning customer dashboard.';
