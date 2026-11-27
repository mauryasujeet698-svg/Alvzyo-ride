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

function pemBytes(pem: string): ArrayBuffer {
  const body = pem.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\\s/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer as ArrayBuffer;
}

async function serviceAccountAccessToken(): Promise<string> {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT_JSON");
  if (!raw) throw new Error("FCM_SERVICE_ACCOUNT_JSON is not configured.");
  const account = JSON.parse(raw) as {
    client_email?: string;
    private_key?: string;
    private_key_id?: string;
  };
  if (!account.client_email || !account.private_key) {
    throw new Error("FCM_SERVICE_ACCOUNT_JSON is missing client_email or private_key.");
  }
  const now = Math.floor(Date.now() / 1000);
  const tokenUrl = "https://oauth2.googleapis.com/token";
  const header = encodeJson({
    alg: "RS256",
    typ: "JWT",
    ...(account.private_key_id ? { kid: account.private_key_id } : {}),
  });
  const claims = encodeJson({
    iss: account.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUrl,
    iat: now,
    exp: now + 300,
  });
  const unsigned = header + "." + claims;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemBytes(account.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  ));
  const assertion = unsigned + "." + base64Url(signature);
  const response = await fetch(tokenUrl, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    signal: AbortSignal.timeout(12000),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || typeof data.access_token !== "string") {
    console.error("FCM service-account OAuth exchange failed", {
      status: response.status,
      error: data.error ?? "unknown_error",
      description: typeof data.error_description === "string"
        ? data.error_description.slice(0, 240)
        : undefined,
    });
    throw new Error("FCM_SERVICE_ACCOUNT_OAUTH_FAILED");
  }
  return data.access_token;
}

async function googleAccessToken(): Promise<string> {
  const nowMs = Date.now();
  const now = Math.floor(nowMs / 1000);
  if (cachedAccessToken && cachedAccessTokenExpiresAt > now + 60) {
    return cachedAccessToken;
  }

  try {
    const privateJwkJson = Deno.env.get("GCP_WIF_PRIVATE_JWK");
    if (!privateJwkJson) throw new Error("GCP_WIF_PRIVATE_JWK is not configured.");
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
      const description = typeof stsData.error_description === "string"
        ? stsData.error_description.slice(0, 300)
        : String(stsData.error ?? "Google STS token exchange failed");
      throw new Error("FCM_WORKLOAD_IDENTITY_EXCHANGE_FAILED: " + description);
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
      throw new Error("FCM_SERVICE_ACCOUNT_IMPERSONATION_FAILED");
    }
    const expiry = typeof impersonationData.expireTime === "string"
      ? Date.parse(impersonationData.expireTime)
      : nowMs + 50 * 60 * 1000;
    cachedAccessToken = impersonationData.accessToken;
    cachedAccessTokenExpiresAt = Number.isFinite(expiry)
      ? Math.floor(expiry / 1000)
      : now + 50 * 60;
    return cachedAccessToken!;
  } catch (wifError) {
    console.error("FCM Workload Identity failed; trying configured service-account fallback", {
      reason: wifError instanceof Error ? wifError.message.slice(0, 240) : "unknown",
    });
    const fallbackToken = await serviceAccountAccessToken();
    cachedAccessToken = fallbackToken;
    cachedAccessTokenExpiresAt = now + 50 * 60;
    return fallbackToken;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  // Publish standards-compliant OIDC discovery and the matching public JWK.
  // This allows Google STS to validate this Supabase Edge Function as its IdP.
  const requestUrl = new URL(req.url);
  if (req.method === "GET" &&
      requestUrl.pathname.endsWith("/.well-known/openid-configuration")) {
    return new Response(JSON.stringify({
      issuer: WIF_ISSUER,
      jwks_uri: WIF_ISSUER + "/.well-known/jwks.json",
      response_types_supported: ["id_token"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "application/json",
        "Cache-Control": "public, max-age=300",
      },
    });
  }
  if (req.method === "GET" &&
      requestUrl.pathname.endsWith("/.well-known/jwks.json")) {
    try {
      const privateJwkJson = Deno.env.get("GCP_WIF_PRIVATE_JWK");
      if (!privateJwkJson) return respond(503, { error: "OIDC_SIGNING_KEY_NOT_CONFIGURED" });
      const privateJwk = JSON.parse(privateJwkJson) as JsonWebKey & { kid?: string };
      if (privateJwk.kty !== "RSA" || !privateJwk.n || !privateJwk.e || !privateJwk.kid) {
        return respond(503, { error: "OIDC_PUBLIC_KEY_NOT_AVAILABLE" });
      }
      return new Response(JSON.stringify({
        keys: [{
          kty: "RSA",
          use: "sig",
          alg: "RS256",
          kid: privateJwk.kid,
          n: privateJwk.n,
          e: privateJwk.e,
        }],
      }), {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
          "Cache-Control": "public, max-age=300",
        },
      });
    } catch {
      return respond(503, { error: "OIDC_PUBLIC_KEY_NOT_AVAILABLE" });
    }
  }

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
  if (!devices?.length) {
    return respond(200, {
      attempted: 0,
      sent: 0,
      stale_tokens_removed: 0,
      message: "No registered devices matched this recipient and application audience.",
    });
  }

  let accessToken: string;
  try {
    accessToken = await googleAccessToken();
  } catch (error) {
    const message = error instanceof Error ? error.message.slice(0, 360) : "FCM authorization failed";
    console.error("FCM authorization failed", message);
    return respond(502, {
      error: "FCM_AUTH_FAILED",
      code: message.startsWith("FCM_WORKLOAD_IDENTITY_EXCHANGE_FAILED")
        ? "FCM_WORKLOAD_IDENTITY_EXCHANGE_FAILED"
        : "FCM_AUTHORIZATION_FAILED",
      message,
    });
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
              token: device.token,
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
