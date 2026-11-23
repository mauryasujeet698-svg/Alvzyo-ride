-- Preserve the existing profile visibility rules while reducing the
-- number of permissive SELECT policies evaluated for each query.

drop policy if exists driver_profiles_customer_read_active_ride on public.driver_profiles;
drop policy if exists driver_profiles_select_own on public.driver_profiles;
create policy driver_profiles_select_own_or_active_ride
on public.driver_profiles
for select
to authenticated
using (
  (select auth.uid()) = user_id
  or exists (
    select 1
    from public.rides r
    where r.driver_id = driver_profiles.user_id
      and r.customer_id = (select auth.uid())
      and r.status in ('accepted', 'driver_arriving', 'arrived', 'in_progress')
  )
);

drop policy if exists profiles_customer_read_active_ride_driver on public.profiles;
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own_or_active_ride_driver
on public.profiles
for select
to authenticated
using (
  (select auth.uid()) = id
  or exists (
    select 1
    from public.rides r
    where r.driver_id = profiles.id
      and r.customer_id = (select auth.uid())
      and r.status in ('accepted', 'driver_arriving', 'arrived', 'in_progress')
  )
);
