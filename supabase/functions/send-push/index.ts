import { createClient } from "npm:@supabase/supabase-js@2.57.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://localhost",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
type Json = Record<string, unknown>;

const respond = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
const GCP_PROJECT_ID = "alvzyo-ride";
const GCP_PROJECT_NUMBER = "178250171089";
const WIF_POOL_ID = "alvzyo-supabase-pool";
const WIF_PROVIDER_ID = "supabase-edge-oidc";
const SERVICE_ACCOUNT_EMAIL =
  "alvzyo-fcm-sender@alvzyo-ride.iam.gserviceaccount.com";
const WIF_ISSUER =
  "https://czbelhtemzklcmssumpc.supabase.co/functions/v1/send-push";
const WIF_SUBJECT = "alvzyo-supabase-edge-fcm";

let cachedAccessToken: string | null = null;
let cachedAccessTokenExpiresAt = 0;

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function encodeJson(value: Json): string {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function providerResource(projectNumber: string): string {
  return (
    "//iam.googleapis.com/projects/" + projectNumber +
    "/locations/global/workloadIdentityPools/" + WIF_POOL_ID +
    "/providers/" + WIF_PROVIDER_ID
  );
}

async function signWorkloadAssertion(privateJwkJson: string, audience: string): Promise<string> {
  let jwk: JsonWebKey & { kid?: string; alg?: string };
  try {
    jwk = JSON.parse(privateJwkJson) as JsonWebKey & { kid?: string; alg?: string };
  } catch {
    throw new Error("GCP_WIF_PRIVATE_JWK is not valid JSON.");
  }

  if (jwk.kty !== "RSA" || !jwk.d || !jwk.n || !jwk.e || !jwk.kid) {
    throw new Error("GCP_WIF_PRIVATE_JWK must be a private RSA JWK with its matching kid.");
  }

  const now = Math.floor(Date.now() / 1000);
  const unsigned = encodeJson({ alg: "RS256", typ: "JWT", kid: jwk.kid }) + "." +
    encodeJson({
      iss: WIF_ISSUER,
      sub: WIF_SUBJECT,
      aud: audience,
      iat: now,
      exp: now + 300,
    });

  const signingKey = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    signingKey,
    new TextEncoder().encode(unsigned),
  ));
  return unsigned + "." + base64Url(signature);
}

async function googleAccessToken(): Promise<string> {
  const nowMs = Date.now();
  const now = Math.floor(nowMs / 1000);
  const cachedToken = cachedAccessToken;
  if (cachedToken && cachedAccessTokenExpiresAt > now + 60) {
    return cachedToken;
  }

  const privateJwkJson = Deno.env.get("GCP_WIF_PRIVATE_JWK");
  if (!privateJwkJson) {
    throw new Error("Missing GCP_WIF_PRIVATE_JWK Supabase secret.");
  }

  const audience = providerResource(GCP_PROJECT_NUMBER);
  const assertion = await signWorkloadAssertion(privateJwkJson, audience);
  const stsResponse = await fetch("https://sts.googleapis.com/v1/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
      audience,
      scope: "https://www.googleapis.com/auth/cloud-platform",
      requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
      subject_token_type: "urn:ietf:params:oauth:token-type:jwt",
      subject_token: assertion,
    }),
    signal: AbortSignal.timeout(12000),
  });

  const stsData = await stsResponse.json().catch(() => ({}));
  if (!stsResponse.ok || typeof stsData.access_token !== "string") {
    console.error("Google STS token exchange failed", {
      status: stsResponse.status,
      error: typeof stsData.error === "string" ? stsData.error : "unknown_error",
    });
    throw new Error("FCM_WORKLOAD_IDENTITY_EXCHANGE_FAILED");
  }

  const impersonationUrl =
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" +
    encodeURIComponent(SERVICE_ACCOUNT_EMAIL) + ":generateAccessToken";
  const impersonationResponse = await fetch(impersonationUrl, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + stsData.access_token,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      scope: ["https://www.googleapis.com/auth/firebase.messaging"],
      lifetime: "3600s",
    }),
    signal: AbortSignal.timeout(12000),
  });

  const impersonationData = await impersonationResponse.json().catch(() => ({}));
  if (!impersonationResponse.ok || typeof impersonationData.accessToken !== "string") {
    console.error("Google service-account impersonation failed", {
      status: impersonationResponse.status,
      error: impersonationData.error?.status ?? "unknown_error",
    });
    throw new Error("FCM_SERVICE_ACCOUNT_IMPERSONATION_FAILED");
  }

  const expiry = typeof impersonationData.expireTime === "string"
    ? Date.parse(impersonationData.expireTime)
    : nowMs + 50 * 60 * 1000;
  cachedAccessToken = impersonationData.accessToken;
  cachedAccessTokenExpiresAt = Number.isFinite(expiry)
    ? Math.floor(expiry / 1000)
    : now + 50 * 60;
  return impersonationData.accessToken;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond(405, { error: "METHOD_NOT_ALLOWED" });

  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const authorization = req.headers.get("Authorization");
  if (!serviceKey || authorization !== `Bearer ${serviceKey}`) {
    return respond(401, { error: "SERVICE_AUTH_REQUIRED" });
  }

  const url = Deno.env.get("SUPABASE_URL");
  if (!url || !Deno.env.get("GCP_WIF_PRIVATE_JWK")) {
    return respond(503, { error: "FCM_NOT_CONFIGURED" });
  }

  let body: Json;
  try {
    body = await req.json();
  } catch {
    return respond(400, { error: "INVALID_JSON" });
  }
  const userIds = Array.isArray(body.userIds)
    ? [...new Set(body.userIds.filter((value): value is string => typeof value === "string" && /^[0-9a-f-]{36}$/i.test(value)))]
      .slice(0, 100)
    : [];
  const appRole = typeof body.appRole === "string" && ["customer", "driver", "admin"].includes(body.appRole)
    ? body.appRole
    : null;
  const title = typeof body.title === "string" ? body.title.trim().slice(0, 100) : "";
  const messageBody = typeof body.body === "string" ? body.body.trim().slice(0, 250) : "";
  const rawData = body.data && typeof body.data === "object" && !Array.isArray(body.data)
    ? body.data as Record<string, unknown>
    : {};
  const data: Record<string, string> = {};
  for (const [key, value] of Object.entries(rawData)) {
    if (/^[a-zA-Z0-9_]{1,40}$/.test(key) && ["string", "number", "boolean"].includes(typeof value)) {
      data[key] = String(value).slice(0, 500);
    }
  }
  if (userIds.length === 0 || !title || !messageBody) {
    return respond(400, { error: "RECIPIENTS_AND_MESSAGE_REQUIRED" });
  }

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  let query = db.from("device_push_tokens").select("id,token,user_id").in("user_id", userIds);
  if (appRole) query = query.eq("app_role", appRole);
  const { data: devices, error: lookupError } = await query;
  if (lookupError) {
    console.error("FCM token lookup failed", lookupError.message);
    return respond(500, { error: "PUSH_RECIPIENT_LOOKUP_FAILED" });
  }
  if (!devices?.length) return respond(200, { attempted: 0, sent: 0, stale_tokens_removed: 0 });

  let accessToken: string;
  try {
    accessToken = await googleAccessToken();
  } catch (error) {
    console.error("FCM authorization failed", String(error));
    return respond(502, { error: "FCM_AUTH_FAILED" });
  }

  const results = await Promise.all(devices.map(async (device: { id: string; token: string }) => {
    try {
      const response = await fetch(
        `https://fcm.googleapis.com/v1/projects/${GCP_PROJECT_ID}/messages:send`,
        {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${accessToken}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: {
              fid: device.token,
              notification: { title, body: messageBody },
              data,
              android: {
                priority: "HIGH",
                notification: { sound: "default" },
              },
              apns: {
                payload: {
                  aps: { sound: "default" },
                },
              },
            },
          }),
          signal: AbortSignal.timeout(12000),
        },
      );
      if (response.ok) return { sent: true, stale: false };
      const resultText = await response.text();
      const stale = response.status === 404 || resultText.includes("UNREGISTERED");
      if (!stale) console.error("FCM send failed", response.status, resultText.slice(0, 400));
      return { sent: false, stale };
    } catch (error) {
      console.error("FCM send request failed", String(error));
      return { sent: false, stale: false };
    }
  }));

  const staleIds = devices.filter((_: unknown, index: number) => results[index].stale).map((device: { id: string }) => device.id);
  if (staleIds.length) {
    const { error } = await db.from("device_push_tokens").delete().in("id", staleIds);
    if (error) console.error("Unable to remove stale FCM tokens", error.message);
  }
  return respond(200, {
    attempted: devices.length,
    sent: results.filter((result: { sent: boolean }) => result.sent).length,
    stale_tokens_removed: staleIds.length,
  });
});
