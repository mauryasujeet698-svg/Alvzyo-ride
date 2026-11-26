-- Determine driver serviceability from the device's current GPS point.
-- The Edge Function authenticates the driver; this RPC is callable only by service_role.
create or replace function public.set_driver_availability_by_location(
  p_driver_id uuid,
  p_longitude double precision,
  p_latitude double precision,
  p_accuracy_m numeric,
  p_online boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_driver public.driver_profiles%rowtype;
  v_pincode public.service_area_pincodes%rowtype;
  v_commercial public.service_area_commercial_configs%rowtype;
  v_point extensions.geography;
begin
  select * into v_driver
  from public.driver_profiles
  where user_id = p_driver_id
  for update;

  if not found or v_driver.verification_status <> 'approved' then
    raise exception 'An approved driver account is required' using errcode = '42501';
  end if;

  if not p_online then
    if exists (
      select 1 from public.rides r
      where r.driver_id = p_driver_id
        and r.status in ('accepted', 'driver_arriving', 'arrived', 'in_progress')
    ) then
      raise exception 'Complete or cancel the active ride before going offline' using errcode = 'P0001';
    end if;
    update public.driver_profiles
    set availability_status = 'offline', active_pincode_id = null
    where user_id = p_driver_id;
    return jsonb_build_object('online', false, 'availability_status', 'offline');
  end if;

  if p_longitude is null or p_latitude is null
     or p_longitude not between -180 and 180
     or p_latitude not between -90 and 90 then
    raise exception 'A valid GPS location is required to go online' using errcode = '22023';
  end if;
  if p_accuracy_m is null or p_accuracy_m < 0 or p_accuracy_m > 100 then
    raise exception 'GPS accuracy is too low. Move to an open area and try again' using errcode = '22023';
  end if;
  if v_driver.availability_status = 'busy' then
    raise exception 'Driver is currently completing another ride' using errcode = 'P0001';
  end if;

  v_point := extensions.st_setsrid(
    extensions.st_makepoint(p_longitude, p_latitude), 4326
  )::extensions.geography;

  select p.* into v_pincode
  from public.service_area_pincodes p
  join public.service_areas a
    on a.id = p.service_area_id
   and a.is_active = true
  where p.is_active = true
    and p.boundary is not null
    and extensions.st_covers(
      p.boundary::extensions.geometry,
      v_point::extensions.geometry
    )
  order by extensions.st_area(p.boundary::extensions.geometry) asc
  limit 1;

  if not found then
    return jsonb_build_object(
      'serviceable', false,
      'online', false,
      'availability_status', 'offline',
      'message', 'Alvzyo rides are not available at your current location yet.'
    );
  end if;

  if exists (
    select 1
    from public.driver_service_pincodes dsp
    where dsp.driver_id = p_driver_id
      and dsp.pincode_id = v_pincode.id
      and dsp.status in ('rejected', 'suspended')
  ) then
    return jsonb_build_object(
      'serviceable', true,
      'online', false,
      'availability_status', 'offline',
      'pincode', v_pincode.pincode,
      'message', 'Your access to this service area is restricted. Contact Alvzyo support.'
    );
  end if;

  select * into v_commercial
  from public.service_area_commercial_configs c
  where c.pincode_id = v_pincode.id
    and c.is_active = true
    and c.valid_from <= now()
    and (c.valid_until is null or c.valid_until > now())
  order by c.valid_from desc
  limit 1;

  if not found then
    return jsonb_build_object(
      'serviceable', true,
      'online', false,
      'availability_status', 'offline',
      'pincode', v_pincode.pincode,
      'message', 'This area is serviceable, but ride operations are not enabled here yet.'
    );
  end if;

  if v_commercial.business_model in ('subscription', 'hybrid') and not exists (
    select 1
    from public.driver_subscriptions ds
    where ds.driver_id = p_driver_id
      and ds.pincode_id = v_pincode.id
      and ds.status = 'active'
      and ds.period_start <= now()
      and ds.period_end > now()
  ) then
    return jsonb_build_object(
      'serviceable', true,
      'online', false,
      'availability_status', 'offline',
      'pincode', v_pincode.pincode,
      'message', 'Your driver subscription for this service area is not active.'
    );
  end if;

  update public.driver_service_pincodes
  set is_primary = false
  where driver_id = p_driver_id
    and pincode_id <> v_pincode.id
    and is_primary = true;

  insert into public.driver_service_pincodes (
    driver_id, pincode_id, status, is_primary, reviewed_by, reviewed_at, review_note
  )
  values (
    p_driver_id, v_pincode.id, 'active', true, null, null, null
  )
  on conflict (driver_id, pincode_id) do update
    set status = 'active',
        is_primary = true,
        reviewed_by = null,
        reviewed_at = null,
        review_note = null;

  update public.driver_profiles
  set availability_status = 'online',
      active_pincode_id = v_pincode.id
  where user_id = p_driver_id;

  return jsonb_build_object(
    'serviceable', true,
    'online', true,
    'availability_status', 'online',
    'pincode_id', v_pincode.id,
    'pincode', v_pincode.pincode,
    'message', 'You are online and ready to receive rides.'
  );
end;
$function$;

revoke all on function public.set_driver_availability_by_location(uuid, double precision, double precision, numeric, boolean) from public;
revoke all on function public.set_driver_availability_by_location(uuid, double precision, double precision, numeric, boolean) from anon;
revoke all on function public.set_driver_availability_by_location(uuid, double precision, double precision, numeric, boolean) from authenticated;
grant execute on function public.set_driver_availability_by_location(uuid, double precision, double precision, numeric, boolean) to service_role;
