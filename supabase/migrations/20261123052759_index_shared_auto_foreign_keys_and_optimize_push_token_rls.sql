-- Add covering indexes for Shared Auto foreign keys and cache the auth
-- identity once per statement in device token access policies.

create index if not exists rides_shared_auto_trip_idx
  on public.rides (shared_auto_trip_id);
create index if not exists shared_auto_configs_updated_by_idx
  on public.shared_auto_configs (updated_by);
create index if not exists shared_auto_trips_driver_id_idx
  on public.shared_auto_trips (driver_id);
create index if not exists shared_auto_trips_lead_ride_id_idx
  on public.shared_auto_trips (lead_ride_id);
create index if not exists shared_auto_trips_service_area_id_idx
  on public.shared_auto_trips (service_area_id);
create index if not exists shared_auto_trips_vehicle_category_id_idx
  on public.shared_auto_trips (vehicle_category_id);

drop policy if exists device_push_tokens_select_own on public.device_push_tokens;
create policy device_push_tokens_select_own
  on public.device_push_tokens for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists device_push_tokens_insert_own on public.device_push_tokens;
create policy device_push_tokens_insert_own
  on public.device_push_tokens for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists device_push_tokens_update_own on public.device_push_tokens;
create policy device_push_tokens_update_own
  on public.device_push_tokens for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists device_push_tokens_delete_own on public.device_push_tokens;
create policy device_push_tokens_delete_own
  on public.device_push_tokens for delete to authenticated
  using ((select auth.uid()) = user_id);
