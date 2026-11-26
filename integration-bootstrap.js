'use strict';

const stageIntegrationOrigin = 'https://cnkwvrxlvvtmfiubtyks.supabase.co';

function stageIntegrationTarget(config, location) {
  if (typeof config?.publishableKey !== 'string' || !config.publishableKey.trim() || config.publishableKey.startsWith('sb_secret_')) return null;
  let target;
  try { target = new URL(config.url); } catch { return null; }
  if (target.href !== target.origin + '/') return null;
  const local = ['127.0.0.1','localhost'].includes(target.hostname) &&
    ['127.0.0.1','localhost'].includes(location.hostname) && target.protocol === 'http:';
  if (local) return { url:target.origin, key:config.publishableKey, hosted:false };
  if (target.origin !== stageIntegrationOrigin ||
      location.origin !== 'https://romakopeiko-cmyk.github.io' ||
      !location.pathname.startsWith('/stage-base/staging/')) return null;
  if (!config.publishableKey.startsWith('sb_publishable_')) return null;
  return { url:target.origin, key:config.publishableKey, hosted:true };
}

async function verifyStageIntegration(target) {
  if (!target.hosted) return true;
  try {
    const response = await fetch(target.url + '/rest/v1/rpc/stage_v1_integration_ready', {
      method:'POST', headers:{apikey:target.key,'Content-Type':'application/json'},
      body:'{}', cache:'no-store', redirect:'error', signal:AbortSignal.timeout(8000)
    });
    return response.ok && await response.json() === true;
  } catch { return false; }
}
