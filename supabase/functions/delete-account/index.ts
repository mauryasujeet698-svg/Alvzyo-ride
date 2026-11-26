import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function response(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return response(405, { error: "METHOD_NOT_ALLOWED" });

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return response(401, { error: "AUTHENTICATION_REQUIRED" });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return response(503, { error: "ACCOUNT_SERVICE_NOT_CONFIGURED" });

  const authClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await authClient.auth.getUser();
  const user = data.user;
  if (error || !user) return response(401, { error: "INVALID_SESSION" });

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Never remove an account while either side is in an active trip.
  const activeStatuses = ["accepted", "driver_arriving", "arrived", "in_progress"];
  const activeRideChecks = await Promise.all([
    admin.from("rides").select("id", { count: "exact", head: true })
      .eq("customer_id", user.id).in("status", activeStatuses),
    admin.from("rides").select("id", { count: "exact", head: true })
      .eq("driver_id", user.id).in("status", activeStatuses),
  ]);
  if (activeRideChecks.some((item) => item.error)) {
    return response(503, { error: "ACTIVE_RIDE_CHECK_FAILED" });
  }
  if (activeRideChecks.some((item) => (item.count ?? 0) > 0)) {
    return response(409, { error: "ACTIVE_RIDE_EXISTS", message: "Complete or cancel the active ride before deleting your account." });
  }

  // These relations deliberately restrict hard deletion to retain ride,
  // payment, ledger, safety and support history with referential integrity.
  const checks = await Promise.all([
    admin.from("rides").select("id", { count: "exact", head: true }).eq("customer_id", user.id),
    admin.from("rides").select("id", { count: "exact", head: true }).eq("driver_id", user.id),
    admin.from("driver_subscriptions").select("id", { count: "exact", head: true }).eq("driver_id", user.id),
    admin.from("ledger_entries").select("id", { count: "exact", head: true }).eq("owner_user_id", user.id),
    admin.from("payment_records").select("id", { count: "exact", head: true }).or("payer_user_id.eq." + user.id + ",payee_user_id.eq." + user.id),
    admin.from("ride_commissions").select("id", { count: "exact", head: true }).eq("driver_id", user.id),
    admin.from("ride_safety_events").select("id", { count: "exact", head: true }).eq("actor_user_id", user.id),
    admin.from("ride_support_tickets").select("id", { count: "exact", head: true }).eq("submitted_by", user.id),
  ]);

  if (checks.some((item) => item.error)) return response(503, { error: "ACCOUNT_RETENTION_CHECK_FAILED" });
  const retainedRecordCount = checks.reduce((sum, item) => sum + (item.count ?? 0), 0);

  // Driver verification files are personal data, not ride-accounting records.
  // Remove the private objects and metadata for both permanent deletion and
  // anonymization paths, then remove device identifiers before deleting auth.
  const { data: documents, error: documentQueryError } = await admin
    .from("driver_documents")
    .select("storage_bucket,object_path")
    .eq("driver_id", user.id);
  if (documentQueryError) return response(503, { error: "DRIVER_DOCUMENT_CLEANUP_FAILED" });

  const documentGroups = new Map<string, string[]>();
  for (const document of documents ?? []) {
    const bucket = typeof document.storage_bucket === "string" ? document.storage_bucket : "";
    const objectPath = typeof document.object_path === "string" ? document.object_path : "";
    if (!bucket || !objectPath) continue;
    const paths = documentGroups.get(bucket) ?? [];
    paths.push(objectPath);
    documentGroups.set(bucket, paths);
  }
  for (const [bucket, paths] of documentGroups) {
    const { error: storageError } = await admin.storage.from(bucket).remove(paths);
    if (storageError) {
      console.error("Driver document storage cleanup failed", { bucket, error: storageError.message });
      return response(503, { error: "DRIVER_DOCUMENT_STORAGE_CLEANUP_FAILED" });
    }
  }
  const { error: documentDeleteError } = await admin
    .from("driver_documents").delete().eq("driver_id", user.id);
  if (documentDeleteError) return response(503, { error: "DRIVER_DOCUMENT_METADATA_CLEANUP_FAILED" });

  const { error: tokenDeleteError } = await admin
    .from("device_push_tokens").delete().eq("user_id", user.id);
  if (tokenDeleteError) return response(503, { error: "DEVICE_TOKEN_CLEANUP_FAILED" });

  if (retainedRecordCount === 0) {
    const { error: deletionError } = await admin.auth.admin.deleteUser(user.id, false);
    if (!deletionError) return response(200, { mode: "permanently_deleted" });
    console.error("Permanent account deletion fell back to anonymization", deletionError.message);
  }

  // Preserve referential integrity: block sign-in and anonymize the profile.
  const { error: banError } = await admin.auth.admin.updateUserById(user.id, {
    ban_duration: "876000h",
    user_metadata: {},
  });
  if (banError) {
    console.error("Unable to block account sign-in", banError.message);
    return response(503, { error: "ACCOUNT_SIGN_IN_COULD_NOT_BE_BLOCKED" });
  }

  const [{ error: profileError }, { error: driverError }] = await Promise.all([
    admin.from("profiles").update({
      full_name: null,
      avatar_url: null,
      phone_e164: null,
      account_status: "deleted",
      updated_at: new Date().toISOString(),
    }).eq("id", user.id),
    admin.from("driver_profiles").update({
      availability_status: "offline",
      active_pincode_id: null,
    }).eq("user_id", user.id),
  ]);
  if (profileError || driverError) {
    console.error("Account blocked but anonymization incomplete", {
      profile: profileError?.message,
      driver: driverError?.message,
    });
    return response(503, { error: "ACCOUNT_BLOCKED_BUT_CLEANUP_INCOMPLETE" });
  }
  return response(200, { mode: "anonymized_retained_records", retained_record_count: retainedRecordCount });
});