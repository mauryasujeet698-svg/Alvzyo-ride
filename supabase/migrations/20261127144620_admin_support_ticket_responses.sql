alter table public.ride_support_tickets
  add column if not exists admin_response text,
  add column if not exists admin_responded_at timestamptz,
  add column if not exists admin_responded_by uuid references auth.users(id) on delete set null;

comment on column public.ride_support_tickets.admin_response
  is 'Latest administrator response visible to the ticket submitter';
