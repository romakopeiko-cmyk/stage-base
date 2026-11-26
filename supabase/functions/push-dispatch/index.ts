import { createClient } from "npm:@supabase/supabase-js@2.49.4";
import webpush from "npm:web-push@3.6.7";

type Job = { job_id: number; lease: string; endpoint: string; p256dh: string; auth_key: string };
type Outcome = "delivered" | "expired" | "retry" | "failed";

const pushHosts = new Set(["web.push.apple.com", "fcm.googleapis.com", "updates.push.services.mozilla.com"]);

function permittedEndpoint(value: string) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && pushHosts.has(url.hostname) && !url.port
      && !url.username && !url.password && !url.hash;
  } catch {
    return false;
  }
}

async function dispatch(job: Job): Promise<Outcome> {
  if (!permittedEndpoint(job.endpoint)) return "failed";
  try {
    // Lock-screen text is intentionally generic. The signed-in inbox supplies details.
    await webpush.sendNotification({
      endpoint: job.endpoint,
      keys: { p256dh: job.p256dh, auth: job.auth_key },
    }, JSON.stringify({ tag: "stage-" + job.job_id }), { TTL: 300, timeout: 7000 });
    return "delivered";
  } catch (error) {
    const code = (error as { statusCode?: number }).statusCode;
    if (code === 404 || code === 410) return "expired";
    return !code || code === 429 || code >= 500 ? "retry" : "failed";
  }
}

Deno.serve(async (request) => {
  const workerKey = Deno.env.get("STAGE_PUSH_WORKER_KEY");
  if (request.method !== "POST" || !workerKey || request.headers.get("x-stage-worker-key") !== workerKey) {
    return new Response(null, { status: 404 });
  }
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const subject = Deno.env.get("STAGE_PUSH_CONTACT");
  const publicKey = Deno.env.get("STAGE_PUSH_PUBLIC_KEY");
  const privateKey = Deno.env.get("STAGE_PUSH_PRIVATE_KEY");
  if (!url || !serviceKey || !subject || !publicKey || !privateKey) {
    return Response.json({ error: "Push configuration is incomplete" }, { status: 503 });
  }
  webpush.setVapidDetails(subject, publicKey, privateKey);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await db.rpc("stage_claim_push");
  if (error) return Response.json({ error: "Unable to claim jobs" }, { status: 500 });

  const jobs = data as Job[];
  let finalizeFailed = false;
  for (let offset = 0; offset < jobs.length; offset += 5) {
    await Promise.all(jobs.slice(offset, offset + 5).map(async (job) => {
      const result = await dispatch(job);
      const { error } = await db.rpc("stage_finish_push", {
        p_job: job.job_id, p_lease: job.lease, p_result: result,
      });
      if (error) finalizeFailed = true;
    }));
  }
  return Response.json({ processed: jobs.length }, { status: finalizeFailed ? 500 : 200 });
});
