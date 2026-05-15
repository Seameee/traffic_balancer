const DEFAULT_ALLOWED_METHODS = ["getUpdates", "sendMessage"];
const HOP_BY_HOP_HEADERS = [
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "host",
  "content-length",
  "x-tg-proxy-secret",
  "cf-connecting-ip",
  "cf-ipcountry",
  "cf-ray",
  "cf-visitor",
  "cdn-loop",
  "x-forwarded-for",
  "x-forwarded-proto",
];

const memoryCounters = new Map();
let cleanupAt = Date.now() + 60_000;

export default {
  async fetch(request, env) {
    try {
      return await handleRequest(request, env);
    } catch {
      return jsonResponse(
        { ok: false, error_code: 502, description: "proxy error" },
        502,
      );
    }
  },
};

async function handleRequest(request, env) {
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === "/health") {
    return new Response("ok\n", {
      headers: { "cache-control": "no-store" },
    });
  }

  if (request.method !== "GET" && request.method !== "POST") {
    return jsonResponse(
      { ok: false, error_code: 405, description: "method not allowed" },
      405,
      { allow: "GET, POST" },
    );
  }

  if (!hasValidProxySecret(request, env)) {
    return deny();
  }

  const route = parseTelegramRoute(url.pathname, env);
  if (!route) {
    return deny();
  }

  const allowedTokens = envList(env.BOT_TOKENS);
  if (!allowedTokens.includes(route.token)) {
    return deny();
  }

  const allowedMethods = envList(env.ALLOWED_METHODS);
  const methodAllowlist = new Set(
    allowedMethods.length ? allowedMethods : DEFAULT_ALLOWED_METHODS,
  );
  if (!methodAllowlist.has(route.method)) {
    return jsonResponse(
      { ok: false, error_code: 403, description: "bot method is not allowed" },
      403,
    );
  }

  const maxBodyBytes = numberEnv(env.MAX_BODY_BYTES, 1024 * 1024);
  const contentLength = Number(request.headers.get("content-length") || "0");
  if (contentLength > maxBodyBytes) {
    return jsonResponse(
      { ok: false, error_code: 413, description: "request body too large" },
      413,
    );
  }

  const rateLimitResult = await checkRateLimits(request, env, route.token);
  if (!rateLimitResult.allowed) {
    return jsonResponse(
      { ok: false, error_code: 429, description: "rate limit exceeded" },
      429,
      { "retry-after": String(rateLimitResult.retryAfter) },
    );
  }

  const upstreamUrl = buildUpstreamUrl(url, route, env);
  const upstreamHeaders = cloneHeadersForUpstream(request.headers);
  const init = {
    method: request.method,
    headers: upstreamHeaders,
    redirect: "manual",
  };

  if (request.method !== "GET") {
    init.body = request.body;
  }

  const upstreamResponse = await fetch(upstreamUrl, init);
  const responseHeaders = cloneHeadersForClient(upstreamResponse.headers);
  responseHeaders.set("cache-control", "no-store");

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    statusText: upstreamResponse.statusText,
    headers: responseHeaders,
  });
}

function hasValidProxySecret(request, env) {
  const allowedSecrets = [
    ...envList(env.PROXY_SECRET),
    ...envList(env.PROXY_SECRETS),
  ];

  if (!allowedSecrets.length) {
    return false;
  }

  const provided = request.headers.get("x-tg-proxy-secret") || "";
  return allowedSecrets.includes(provided);
}

function parseTelegramRoute(pathname, env) {
  const basePath = normalizeBasePath(env.BASE_PATH || "");
  let path = pathname;

  if (basePath) {
    if (path !== basePath && !path.startsWith(`${basePath}/`)) {
      return null;
    }
    path = path.slice(basePath.length) || "/";
  }

  const match = path.match(
    /^\/bot([0-9]{6,20}:[A-Za-z0-9_-]{30,})\/([A-Za-z][A-Za-z0-9_]*)$/,
  );

  if (!match) {
    return null;
  }

  return {
    token: match[1],
    method: match[2],
  };
}

function buildUpstreamUrl(sourceUrl, route, env) {
  const upstream = new URL(
    `https://api.telegram.org/bot${route.token}/${route.method}`,
  );
  upstream.search = sourceUrl.search;

  if (route.method === "getUpdates") {
    const maxTimeout = numberEnv(env.MAX_GETUPDATES_TIMEOUT, 10);
    const timeout = Number(upstream.searchParams.get("timeout") || "0");
    if (Number.isFinite(timeout) && timeout > maxTimeout) {
      upstream.searchParams.set("timeout", String(maxTimeout));
    }
  }

  return upstream.toString();
}

async function checkRateLimits(request, env, token) {
  const ip = request.headers.get("cf-connecting-ip") || "unknown";
  const now = Math.floor(Date.now() / 1000);
  const windowSize = numberEnv(env.RATE_LIMIT_WINDOW_SECONDS, 60);
  const windowId = Math.floor(now / windowSize);
  const ttl = windowSize * 2;
  const tokenHash = await sha256Short(token);
  const ipHash = await sha256Short(ip);

  const perIpLimit = numberEnv(env.RATE_LIMIT_PER_IP, 60);
  const perBotLimit = numberEnv(env.RATE_LIMIT_PER_BOT, 240);

  const ipAllowed = await incrementAndCheck(
    env,
    `tg:${tokenHash}:ip:${ipHash}:${windowId}`,
    perIpLimit,
    ttl,
  );
  if (!ipAllowed) {
    return { allowed: false, retryAfter: windowSize };
  }

  const botAllowed = await incrementAndCheck(
    env,
    `tg:${tokenHash}:bot:${windowId}`,
    perBotLimit,
    ttl,
  );
  if (!botAllowed) {
    return { allowed: false, retryAfter: windowSize };
  }

  return { allowed: true, retryAfter: 0 };
}

async function incrementAndCheck(env, key, limit, ttlSeconds) {
  if (!Number.isFinite(limit) || limit <= 0) {
    return true;
  }

  if (env.RATE_KV) {
    const current = Number((await env.RATE_KV.get(key)) || "0");
    if (current >= limit) {
      return false;
    }
    await env.RATE_KV.put(key, String(current + 1), {
      expirationTtl: ttlSeconds,
    });
    return true;
  }

  const now = Date.now();
  if (now >= cleanupAt) {
    cleanupAt = now + 60_000;
    for (const [bucketKey, bucket] of memoryCounters.entries()) {
      if (bucket.expiresAt <= now) {
        memoryCounters.delete(bucketKey);
      }
    }
  }

  const bucket = memoryCounters.get(key);
  if (!bucket || bucket.expiresAt <= now) {
    memoryCounters.set(key, {
      count: 1,
      expiresAt: now + ttlSeconds * 1000,
    });
    return true;
  }

  if (bucket.count >= limit) {
    return false;
  }

  bucket.count += 1;
  return true;
}

function cloneHeadersForUpstream(headers) {
  const cloned = new Headers(headers);

  for (const name of HOP_BY_HOP_HEADERS) {
    cloned.delete(name);
  }

  return cloned;
}

function cloneHeadersForClient(headers) {
  const cloned = new Headers(headers);

  for (const name of HOP_BY_HOP_HEADERS) {
    cloned.delete(name);
  }

  cloned.delete("set-cookie");
  return cloned;
}

function envList(value) {
  return String(value || "")
    .split(/[\n,]/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function numberEnv(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function normalizeBasePath(path) {
  if (!path) {
    return "";
  }
  return `/${String(path).replace(/^\/+|\/+$/g, "")}`;
}

async function sha256Short(value) {
  const data = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 16);
}

function deny() {
  return new Response("not found\n", {
    status: 404,
    headers: { "cache-control": "no-store" },
  });
}

function jsonResponse(body, status, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...headers,
    },
  });
}
