#!/usr/bin/env node
// DeepSeek Harness Web 反向代理。
//
// 背景：
// dsh 拒绝监听 0.0.0.0，并且会对 HTTP 的 Host/Origin 做安全校验。
// 浏览器使用任意服务器 IP 或域名访问时，Host 不是回环地址，
// 直接转发会被 dsh 的 /api 信任围栏拒绝。
//
// 本代理的策略：
//   浏览器任意 Host:2224（宿主机端口）
//     -> Docker 映射到容器 3080
//     -> 代理监听容器 0.0.0.0:3080
//     -> 把 Host 改写为 127.0.0.1:3081
//     -> 删除 Origin
//     -> 转发给 dsh 127.0.0.1:3081
//
// 因此不需要维护访问地址白名单，任意访问地址都能使用。
//
// token 处理：
// dsh 每次启动都会生成随机临时 token。start-dsh-web.sh 会从启动日志中
// 捕获真实 token 并写入 /run/dsh-web-token。本代理把 Compose 中配置的
// 固定 DSH_WEB_TOKEN 自动替换成真实 token，因此用户始终访问：
//   http://任意地址:2224/?token=<DSH_WEB_TOKEN>
// 不需要每次从日志中复制新的随机 token。
//
// 登录方式：
// - 直接访问 http://任意地址:2224/ 会显示代理登录页；
// - 输入 DSH_WEB_PASSWORD 或 DSH_WEB_TOKEN 后写入签名 Cookie；
// - 登录成功时代理用真实 token 向 dsh 交换一次会话 Cookie，
//   之后浏览器凭 Cookie 访问，地址栏既不显示 token，也不会反复跳转；
// - dsh 会话过期或缺失时，代理会自动恢复一次；
// - 旧的 ?token=<DSH_WEB_TOKEN> 链接仍然可用，并会同时写入 Cookie。
//
// 该行为会绕过 dsh 针对恶意 Host 的额外防护，只应运行在可信网络中。

"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");

// 代理在容器内对外监听所有 IPv4 网卡的 3080，宿主机映射端口为 2224。
const LISTEN_HOST = "0.0.0.0";
const LISTEN_PORT = 3080;

// dsh 只监听容器回环地址，外部无法直接连接 3081。
const UPSTREAM_HOST = "127.0.0.1";
const UPSTREAM_PORT = 3081;

// dsh 的 Host 校验接受回环权威地址，所以统一改写为该 authority。
const UPSTREAM_AUTHORITY = `${UPSTREAM_HOST}:${UPSTREAM_PORT}`;

// Compose 中配置的固定 token，以及 start-dsh-web.sh 捕获真实 token 的文件位置。
// 两者都允许通过环境变量覆盖，便于测试和后续扩展。
const DSH_WEB_TOKEN = process.env.DSH_WEB_TOKEN ?? "";
const DSH_TOKEN_FILE = process.env.DSH_TOKEN_FILE ?? "/run/dsh-web-token";

// 登录页密码。为空时只接受 DSH_WEB_TOKEN。
// 登录页同时接受 DSH_WEB_PASSWORD 和 DSH_WEB_TOKEN。
const DSH_WEB_PASSWORD = process.env.DSH_WEB_PASSWORD ?? "";

// 代理登录 Cookie 名称和有效期。
// 代理登录有效期 7 天；dsh 自己的会话 Cookie 默认 30 天。
// 代理 Cookie 先过期，所以实际体验是每 7 天需要重新输入一次密码。
const AUTH_COOKIE = "dsh_proxy_auth";
const AUTH_TTL_SECONDS = 7 * 24 * 60 * 60;
const AUTH_SECRET = DSH_WEB_PASSWORD || DSH_WEB_TOKEN;
const MAX_LOGIN_BODY_BYTES = 4096;

// dsh 自己的浏览器会话 Cookie 名称。
// dsh 使用 "dsh-auth-" + base64url(sha256(Host)) 生成该名称。
// 代理把 Host 固定改写为 UPSTREAM_AUTHORITY，因此可以提前算出同一个名字。
// 请求已经带有该 Cookie 时不能再注入 token：dsh 只要在 GET / 上看到 token，
// 即使 Cookie 有效也会返回 303 清理地址栏，代理继续注入就会形成无限重定向。
const DSH_AUTH_COOKIE = `dsh-auth-${
    crypto.createHash("sha256").update(UPSTREAM_AUTHORITY).digest("base64url")
}`;

// dsh 会话失效时的自动恢复标记。
// 恢复过程会重新交换一次 Cookie；如果恢复后仍然 401，这个短期 Cookie
// 会让代理直接返回 401，而不是再次跳转，避免出现新的重定向循环。
const REAUTH_GUARD_COOKIE = "dsh_proxy_reauth_guard";
const REAUTH_GUARD_TTL_SECONDS = 10;

// 没有固定 token 就无法提供稳定的登录入口，直接让 Supervisor 报错并重启。
if (DSH_WEB_TOKEN.length === 0) {
    console.error("dsh-proxy: DSH_WEB_TOKEN is required");
    process.exit(1);
}

// 常量时间字符串比较，避免通过响应时间猜测密码。
function safeEqual(input, expected) {
    const inputBuffer = Buffer.from(input, "utf8");
    const expectedBuffer = Buffer.from(expected, "utf8");
    if (inputBuffer.length !== expectedBuffer.length) return false;
    return crypto.timingSafeEqual(inputBuffer, expectedBuffer);
}

// 登录 Cookie 使用 HMAC 签名，不依赖服务端会话存储。
function authSignature(payload) {
    return crypto.createHmac("sha256", AUTH_SECRET).update(payload).digest("base64url");
}

// 只有 HTTPS 或反向代理明确声明 HTTPS 时才给 Cookie 加 Secure。
function isSecureRequest(request) {
    if (request.socket.encrypted) return true;
    const forwardedProto = request.headers["x-forwarded-proto"];
    return typeof forwardedProto === "string"
        && forwardedProto.split(",")[0].trim().toLowerCase() === "https";
}

function createAuthCookie(secure) {
    const expires = Math.floor(Date.now() / 1000) + AUTH_TTL_SECONDS;
    const payload = `v1.${expires}`;
    const parts = [
        `${AUTH_COOKIE}=${payload}.${authSignature(payload)}`,
        "Path=/",
        "HttpOnly",
        "SameSite=Lax",
        `Max-Age=${AUTH_TTL_SECONDS}`,
    ];
    if (secure) parts.push("Secure");
    return parts.join("; ");
}

function clearAuthCookie() {
    return `${AUTH_COOKIE}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`;
}

// dsh 会话恢复跳转前写入的一次性标记，短期有效，用来阻止恢复失败时反复跳转。
function createReauthGuardCookie(secure) {
    const parts = [
        `${REAUTH_GUARD_COOKIE}=1`,
        "Path=/",
        "HttpOnly",
        "SameSite=Lax",
        `Max-Age=${REAUTH_GUARD_TTL_SECONDS}`,
    ];
    if (secure) parts.push("Secure");
    return parts.join("; ");
}

function parseCookies(header) {
    const cookies = new Map();
    if (typeof header !== "string") return cookies;

    for (const item of header.split(";")) {
        const separator = item.indexOf("=");
        if (separator < 0) continue;

        const name = item.slice(0, separator).trim();
        const rawValue = item.slice(separator + 1).trim();
        if (name.length === 0) continue;

        try {
            cookies.set(name, decodeURIComponent(rawValue));
        } catch {
            // 忽略格式错误的 Cookie，避免一个坏 Cookie 影响整个请求。
        }
    }

    return cookies;
}

function isAuthenticated(request) {
    const value = parseCookies(request.headers.cookie).get(AUTH_COOKIE);
    if (!value) return false;

    const separator = value.lastIndexOf(".");
    if (separator <= 0) return false;

    const payload = value.slice(0, separator);
    const signature = value.slice(separator + 1);
    const expected = authSignature(payload);
    const signatureBuffer = Buffer.from(signature);
    const expectedBuffer = Buffer.from(expected);

    if (signatureBuffer.length !== expectedBuffer.length) return false;
    if (!crypto.timingSafeEqual(signatureBuffer, expectedBuffer)) return false;

    const [version, expiresText] = payload.split(".");
    if (version !== "v1") return false;

    const expires = Number(expiresText);
    return Number.isFinite(expires) && expires > Math.floor(Date.now() / 1000);
}

// 浏览器是否已经带着 dsh 自己的会话 Cookie。
// 名字由固定 Host 计算而来，不需要解析或验证 Cookie 内容。
function hasDshSession(request) {
    return parseCookies(request.headers.cookie).has(DSH_AUTH_COOKIE);
}

// 恢复流程的一次性标记是否已经存在。
function hasReauthGuard(request) {
    return parseCookies(request.headers.cookie).has(REAUTH_GUARD_COOKIE);
}

function passwordMatches(value) {
    return [DSH_WEB_PASSWORD, DSH_WEB_TOKEN]
        .filter((candidate) => candidate.length > 0)
        .some((candidate) => safeEqual(value, candidate));
}

// 登录后的跳转地址只允许本站绝对路径，避免开放重定向。
// token 参数会被移除，防止登录后地址栏又出现 token。
function sanitizeNextPath(value) {
    if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) {
        return "/";
    }
    if (/[\r\n\\]/.test(value)) return "/";

    try {
        const parsed = new URL(value, "http://localhost");
        if (parsed.origin !== "http://localhost") return "/";
        if (parsed.pathname.startsWith("/__login") || parsed.pathname.startsWith("/__logout")) {
            return "/";
        }
        parsed.searchParams.delete("token");
        return `${parsed.pathname}${parsed.search}`;
    } catch {
        return "/";
    }
}

function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (character) => ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
    })[character]);
}

function loginPage({ error = "", next = "/" } = {}) {
    const safeNext = escapeHtml(sanitizeNextPath(next));
    const errorBlock = error
        ? `<p class="error" role="alert">${escapeHtml(error)}</p>`
        : "";

    return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DeepSeek Harness 登录</title>
<style>
:root {
    color-scheme: light dark;
    font-family: system-ui, -apple-system, "Segoe UI", "Noto Sans CJK SC", sans-serif;
}
body {
    margin: 0;
    min-height: 100vh;
    display: grid;
    place-items: center;
    background: #f3f5f8;
    color: #1f2328;
}
main {
    width: min(88vw, 360px);
    padding: 30px;
    border: 1px solid #d8dee4;
    border-radius: 16px;
    background: #ffffff;
    box-shadow: 0 12px 36px rgba(31, 35, 40, 0.12);
}
h1 { margin: 0 0 8px; font-size: 1.35rem; }
.hint, .note { color: #59636e; font-size: 0.9rem; line-height: 1.5; }
.note { margin: 18px 0 0; }
label { display: block; margin: 20px 0 8px; font-size: 0.9rem; font-weight: 600; }
input {
    width: 100%;
    box-sizing: border-box;
    padding: 11px 12px;
    border: 1px solid #afb8c1;
    border-radius: 8px;
    font: inherit;
}
input:focus { outline: 2px solid #0969da; outline-offset: 1px; border-color: #0969da; }
button {
    width: 100%;
    margin-top: 14px;
    padding: 11px 12px;
    border: 0;
    border-radius: 8px;
    background: #0969da;
    color: #ffffff;
    font: inherit;
    font-weight: 600;
    cursor: pointer;
}
button:hover { background: #0550ae; }
.error {
    margin: 12px 0 0;
    padding: 10px 12px;
    border-radius: 8px;
    background: #ffebe9;
    color: #b42318;
    font-size: 0.9rem;
}
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
@media (prefers-color-scheme: dark) {
    body { background: #0d1117; color: #e6edf3; }
    main { background: #161b22; border-color: #30363d; box-shadow: none; }
    .hint, .note { color: #8b949e; }
    input { background: #0d1117; color: #e6edf3; border-color: #484f58; }
    .error { background: #3d1214; color: #ffb3ad; }
}
</style>
</head>
<body>
<main>
<h1>DeepSeek Harness</h1>
<p class="hint">请输入访问密码或 Token。</p>
${errorBlock}
<form method="post" action="/__login">
<input type="hidden" name="next" value="${safeNext}">
<label for="password">密码或 Token</label>
<input id="password" name="password" type="password" autocomplete="current-password" spellcheck="false" required autofocus>
<button type="submit">登录</button>
</form>
<p class="note">登录后地址栏不会显示 Token；旧的 <code>?token=...</code> 链接仍然可用。</p>
</main>
</body>
</html>`;
}

function sendLoginPage(response, { status = 200, error = "", next = "/" } = {}) {
    const body = Buffer.from(loginPage({ error, next }), "utf8");
    response.writeHead(status, {
        "content-type": "text/html; charset=utf-8",
        "content-length": body.length,
        "cache-control": "no-store",
        "x-frame-options": "DENY",
        "referrer-policy": "no-referrer",
        "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    });
    response.end(body);
}

function redirect(response, location, status = 303) {
    response.writeHead(status, {
        location,
        "cache-control": "no-store",
    });
    response.end();
}

function readRequestBody(request, limit) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let total = 0;
        let failed = false;

        request.on("data", (chunk) => {
            if (failed) return;
            total += chunk.length;
            if (total > limit) {
                failed = true;
                reject(new Error("request body too large"));
                return;
            }
            chunks.push(chunk);
        });

        request.on("end", () => {
            if (!failed) resolve(Buffer.concat(chunks).toString("utf8"));
        });

        request.on("error", (error) => {
            if (!failed) {
                failed = true;
                reject(error);
            }
        });
    });
}

// 读取 dsh 本次进程的真实随机 token。
function readActualDshToken() {
    try {
        return fs.readFileSync(DSH_TOKEN_FILE, "utf8").trim();
    } catch {
        return "";
    }
}

// 用真实 token 向 dsh 交换一次浏览器会话 Cookie。
// dsh 只在 GET / 上接受 token，并返回 303 和 Set-Cookie。
// 登录成功或会话恢复时调用一次，浏览器地址栏不会出现 token。
function mintDshSessionCookie() {
    const actualToken = readActualDshToken();
    if (actualToken.length === 0) return Promise.resolve(null);

    return new Promise((resolve) => {
        let settled = false;
        const finish = (cookies) => {
            if (settled) return;
            settled = true;
            resolve(cookies);
        };

        const upstreamRequest = http.request(
            {
                host: UPSTREAM_HOST,
                port: UPSTREAM_PORT,
                method: "GET",
                path: `/?token=${encodeURIComponent(actualToken)}`,
                headers: {
                    host: UPSTREAM_AUTHORITY,
                    accept: "text/html",
                },
                timeout: 3000,
            },
            (upstreamResponse) => {
                upstreamResponse.resume();

                const setCookie = upstreamResponse.headers["set-cookie"];
                if (Array.isArray(setCookie)) {
                    finish(setCookie);
                } else if (typeof setCookie === "string") {
                    finish([setCookie]);
                } else {
                    finish(null);
                }
            },
        );

        upstreamRequest.on("timeout", () => upstreamRequest.destroy());
        upstreamRequest.on("error", () => finish(null));
        upstreamRequest.end();
    });
}

async function handleLogin(request, response, requestUrl) {
    if (request.method === "GET" || request.method === "HEAD") {
        const next = sanitizeNextPath(requestUrl.searchParams.get("next") ?? "/");
        if (isAuthenticated(request)) {
            redirect(response, next);
            return;
        }
        sendLoginPage(response, { next });
        return;
    }

    if (request.method !== "POST") {
        response.writeHead(405, {
            allow: "GET, POST",
            "content-type": "text/plain; charset=utf-8",
        });
        response.end("Method Not Allowed\n");
        return;
    }

    let body;
    try {
        body = await readRequestBody(request, MAX_LOGIN_BODY_BYTES);
    } catch {
        sendLoginPage(response, {
            status: 413,
            error: "提交内容太大。",
        });
        return;
    }

    const form = new URLSearchParams(body);
    const password = form.get("password") ?? "";
    const next = sanitizeNextPath(form.get("next") ?? "/");

    if (!passwordMatches(password)) {
        sendLoginPage(response, {
            status: 401,
            error: "密码或 Token 不正确。",
            next,
        });
        return;
    }

    // 登录成功时顺便建立 dsh 自己的会话 Cookie。
    // 这样后续普通请求可以只靠 Cookie 通过 dsh 认证，不必在每个请求上注入 token。
    let dshCookies = [];
    if (!hasDshSession(request)) {
        dshCookies = (await mintDshSessionCookie()) ?? [];
    }

    response.writeHead(303, {
        location: next,
        "set-cookie": [createAuthCookie(isSecureRequest(request)), ...dshCookies],
        "cache-control": "no-store",
    });
    response.end();
}

// 会话恢复：代理登录仍然有效，但 dsh Cookie 缺失或过期时，
// 用真实 token 重新交换一次 dsh Cookie，再回到原路径。
// 恢复响应会带一个短期标记；如果恢复后仍然 401，代理不会再跳转。
async function handleReauth(request, response, requestUrl) {
    if (request.method !== "GET" && request.method !== "HEAD") {
        response.writeHead(405, {
            allow: "GET, HEAD",
            "content-type": "text/plain; charset=utf-8",
        });
        response.end("Method Not Allowed\n");
        return;
    }

    const next = sanitizeNextPath(requestUrl.searchParams.get("next") ?? "/");

    if (!isAuthenticated(request)) {
        redirect(response, `/__login?next=${encodeURIComponent(next)}`, 302);
        return;
    }

    const dshCookies = await mintDshSessionCookie();
    if (dshCookies === null || dshCookies.length === 0) {
        response.writeHead(503, {
            "content-type": "text/plain; charset=utf-8",
            "retry-after": "2",
            "cache-control": "no-store",
        });
        response.end("DeepSeek Harness session is not ready. Retry in a moment.\n");
        return;
    }

    response.writeHead(303, {
        location: next,
        "set-cookie": [createReauthGuardCookie(isSecureRequest(request)), ...dshCookies],
        "cache-control": "no-store",
    });
    response.end();
}

// 将浏览器 URL 中的固定 token 替换为 dsh 本次进程的真实随机 token。
// - 带固定 token 的旧链接仍然可用，并会顺便写入登录 Cookie。
// - token 与 Compose 固定值不一致时原样转发，避免代理掩盖错误凭据。
// - 代理已登录但还没有 dsh 会话 Cookie 时，只对 GET 根路径自动注入一次，
//   dsh 会返回 303 并种下它自己的 Cookie；之后的请求靠 Cookie 通过认证。
// - 请求已经带有 dsh 会话 Cookie 时绝不再注入 token，否则 dsh 会一直 303。
// - 需要注入 token 但捕获文件尚未生成时返回 tokenError，由调用方返回 503。
function translateRequestUrl(
    rawUrl,
    {
        authenticated = false,
        hasSession = false,
        allowAutoInject = false,
    } = {},
) {
    let parsed;

    try {
        parsed = new URL(rawUrl, `http://${UPSTREAM_AUTHORITY}`);
    } catch {
        return { url: rawUrl, tokenError: false, providedFixedToken: false };
    }

    const token = parsed.searchParams.get("token");
    const hasToken = token !== null && token.length > 0;
    const providedFixedToken = hasToken && token === DSH_WEB_TOKEN;

    // 未登录且没有固定 token：保持原样，让 dsh 自己返回 401。
    // 带其他 token（例如日志里的真实随机 token）也原样转发。
    if (!providedFixedToken && (!authenticated || hasToken)) {
        return { url: rawUrl, tokenError: false, providedFixedToken: false };
    }

    // 浏览器已经有 dsh 会话，或者当前请求不适合注入（非根路径、API、WebSocket）：
    // 原样转发，靠 Cookie 认证。
    if (!providedFixedToken && (hasSession || !allowAutoInject)) {
        return { url: rawUrl, tokenError: false, providedFixedToken: false };
    }

    const actualToken = readActualDshToken();
    if (actualToken.length === 0) {
        return { url: rawUrl, tokenError: true, providedFixedToken };
    }

    parsed.searchParams.set("token", actualToken);
    return {
        url: `${parsed.pathname}${parsed.search}`,
        tokenError: false,
        providedFixedToken,
    };
}

// HTTP 代理不应原样转发的逐跳（hop-by-hop）请求/响应头。
// 删除这些头后，由 Node.js 根据实际连接重新生成正确的值。
const HOP_BY_HOP_HEADERS = new Set([
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
]);

// 改写发给 dsh 的请求头：
// - Host 固定为回环 authority，使任意外部访问地址都能通过 dsh 的 Host 校验；
// - 删除 Origin，避免它与改写后的 Host 不一致而被 /api 拒绝；
// - 删除代理自身的认证头，避免泄露给 dsh；
// - 其余业务头（Cookie、Content-Type 等）原样保留。
//
// WebSocket Upgrade 请求必须保留 Connection 和 Upgrade 头；
// 普通 HTTP 请求则需要移除这些逐跳头。
function forwardHeaders(originalHeaders, { preserveUpgrade = false } = {}) {
    const headers = {};

    for (const [name, value] of Object.entries(originalHeaders)) {
        const lowerName = name.toLowerCase();

        if (value === undefined) continue;
        if (lowerName === "host") continue;
        if (lowerName === "origin") continue;
        if (lowerName === "referer") continue;
        if (lowerName === "proxy-authorization") continue;

        const isUpgradeHeader = lowerName === "connection" || lowerName === "upgrade";
        if (HOP_BY_HOP_HEADERS.has(lowerName) && !(preserveUpgrade && isUpgradeHeader)) {
            continue;
        }

        headers[name] = value;
    }

    headers.host = UPSTREAM_AUTHORITY;
    return headers;
}

// dsh 的登录成功重定向通常是相对路径 "./"，无需处理。
// 如果 dsh 返回绝对的回环地址，则改成相对路径，
// 防止浏览器被重定向到用户自己电脑上的 127.0.0.1:3081。
function rewriteLocation(location) {
    if (typeof location !== "string") return location;

    const upstreamPrefixes = [
        `http://${UPSTREAM_AUTHORITY}`,
        `https://${UPSTREAM_AUTHORITY}`,
        `http://localhost:${UPSTREAM_PORT}`,
        `https://localhost:${UPSTREAM_PORT}`,
    ];

    for (const prefix of upstreamPrefixes) {
        if (location === prefix) return "/";
        if (location.startsWith(`${prefix}/`)) {
            return location.slice(prefix.length);
        }
    }

    return location;
}

// 如果 dsh 在跳转地址里带上了真实 token，把 token 去掉。
// 浏览器地址栏不需要暴露 token。
function stripTokenFromLocation(location) {
    if (typeof location !== "string") return location;

    try {
        const parsed = new URL(location, "http://localhost");
        if (parsed.origin !== "http://localhost") return location;
        if (!parsed.searchParams.has("token")) return location;
        parsed.searchParams.delete("token");
        return `${parsed.pathname}${parsed.search}`;
    } catch {
        return location;
    }
}

// 判断一个 401 是否应该触发 dsh 会话恢复。
// 只处理代理已登录、浏览器导航（Accept 含 text/html）的 GET/HEAD，
// API 请求和恢复失败后的再次 401 都直接原样返回，避免误跳转或循环。
function shouldReauthenticate(request, response, authenticated, requestUrl) {
    if (!authenticated) return false;
    if (response.statusCode !== 401) return false;
    if (request.method !== "GET" && request.method !== "HEAD") return false;

    const path = requestUrl.pathname;
    if (path === "/api" || path.startsWith("/api/")) return false;
    if (hasReauthGuard(request)) return false;

    const accept = request.headers.accept;
    return typeof accept === "string" && accept.includes("text/html");
}

// 普通 HTTP 请求处理。
// 请求体通过管道直接流式转发，不把上传文件整体读入内存。
const server = http.createServer((clientRequest, clientResponse) => {
    let requestUrl;
    try {
        requestUrl = new URL(clientRequest.url ?? "/", "http://localhost");
    } catch {
        clientResponse.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
        clientResponse.end("Bad Request\n");
        return;
    }

    if (requestUrl.pathname === "/__login") {
        void handleLogin(clientRequest, clientResponse, requestUrl);
        return;
    }

    if (requestUrl.pathname === "/__logout") {
        clientResponse.writeHead(303, {
            location: "/__login",
            "set-cookie": clearAuthCookie(),
            "cache-control": "no-store",
        });
        clientResponse.end();
        return;
    }

    if (requestUrl.pathname === "/__dsh_reauth") {
        void handleReauth(clientRequest, clientResponse, requestUrl);
        return;
    }

    const authenticated = isAuthenticated(clientRequest);
    const sessionPresent = hasDshSession(clientRequest);
    const requestedToken = requestUrl.searchParams.get("token");

    // 没有登录 Cookie，也没有带 token：浏览器显示登录页。
    if (!authenticated && (requestedToken === null || requestedToken.length === 0)) {
        if (clientRequest.method === "GET" || clientRequest.method === "HEAD") {
            if (requestUrl.pathname === "/" || requestUrl.pathname === "/index.html") {
                const next = sanitizeNextPath(`${requestUrl.pathname}${requestUrl.search}`);
                sendLoginPage(clientResponse, { next });
            } else {
                const next = `${requestUrl.pathname}${requestUrl.search}`;
                redirect(clientResponse, `/__login?next=${encodeURIComponent(next)}`, 302);
            }
        } else {
            clientResponse.writeHead(401, {
                "content-type": "text/plain; charset=utf-8",
                "cache-control": "no-store",
            });
            clientResponse.end("Authentication required.\n");
        }
        return;
    }

    const translated = translateRequestUrl(clientRequest.url, {
        authenticated,
        hasSession: sessionPresent,
        // dsh 只在 GET / 上接受 token；HEAD 不注入，交给会话恢复处理。
        allowAutoInject: clientRequest.method === "GET" && requestUrl.pathname === "/",
    });

    // dsh 可能刚启动，还没打印出真实 token。
    // 返回 503 而不是把固定 token 直接发给 dsh，避免得到难以理解的 401。
    if (translated.tokenError) {
        clientResponse.writeHead(503, {
            "content-type": "text/plain; charset=utf-8",
            "retry-after": "2",
            "cache-control": "no-store",
        });
        clientResponse.end("DeepSeek Harness token is not ready. Retry in a moment.\n");
        return;
    }

    const upstreamRequest = http.request(
        {
            host: UPSTREAM_HOST,
            port: UPSTREAM_PORT,
            method: clientRequest.method,
            path: translated.url,
            headers: forwardHeaders(clientRequest.headers),
        },
        (upstreamResponse) => {
            // dsh Cookie 缺失或过期时，先内部恢复一次，避免用户看到裸 401。
            // API 请求和恢复后的再次 401 不跳转。
            if (shouldReauthenticate(clientRequest, upstreamResponse, authenticated, requestUrl)) {
                upstreamResponse.resume();

                const next = `${requestUrl.pathname}${requestUrl.search}`;
                clientResponse.writeHead(302, {
                    location: `/__dsh_reauth?next=${encodeURIComponent(next)}`,
                    "set-cookie": createReauthGuardCookie(isSecureRequest(clientRequest)),
                    "cache-control": "no-store",
                });
                clientResponse.end();
                return;
            }

            const responseHeaders = { ...upstreamResponse.headers };

            // 清理逐跳响应头，并修正可能指向容器回环地址的 Location。
            for (const name of Object.keys(responseHeaders)) {
                if (HOP_BY_HOP_HEADERS.has(name.toLowerCase())) {
                    delete responseHeaders[name];
                }
            }

            // 只有响应确实包含 Location 时才改写，避免把 undefined 写入响应头。
            if (responseHeaders.location !== undefined) {
                let location = rewriteLocation(responseHeaders.location);
                if (authenticated || translated.providedFixedToken) {
                    location = stripTokenFromLocation(location);
                }
                responseHeaders.location = location;
            }

            // 使用旧的固定 token 链接登录时，同时写入长期登录 Cookie。
            if (translated.providedFixedToken) {
                const authCookie = createAuthCookie(isSecureRequest(clientRequest));
                const existingCookie = responseHeaders["set-cookie"];
                if (existingCookie === undefined) {
                    responseHeaders["set-cookie"] = authCookie;
                } else if (Array.isArray(existingCookie)) {
                    responseHeaders["set-cookie"] = [...existingCookie, authCookie];
                } else {
                    responseHeaders["set-cookie"] = [existingCookie, authCookie];
                }
            }

            clientResponse.writeHead(
                upstreamResponse.statusCode ?? 502,
                upstreamResponse.statusMessage,
                responseHeaders,
            );
            upstreamResponse.pipe(clientResponse);
        },
    );

    // 上游 dsh 未启动或连接失败时返回 502，Supervisor 会自动重启 dsh。
    upstreamRequest.on("error", (error) => {
        console.error(`dsh-proxy: upstream request failed: ${error.message}`);
        if (!clientResponse.headersSent) {
            clientResponse.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
        }
        clientResponse.end("Bad Gateway: DeepSeek Harness is unavailable.\n");
    });

    // 浏览器提前断开时，同时终止上游请求，避免资源泄漏。
    clientRequest.on("aborted", () => upstreamRequest.destroy());
    clientRequest.pipe(upstreamRequest);
});

// WebSocket 和 dsh 的 /api/remote.mux 使用 HTTP Upgrade。
// 这里用原始 TCP 管道转发，从而保留长连接、Ping/Pong 和二进制帧。
server.on("upgrade", (clientRequest, clientSocket, head) => {
    clientSocket.on("error", () => {});

    let requestUrl;
    try {
        requestUrl = new URL(clientRequest.url ?? "/", "http://localhost");
    } catch {
        clientSocket.end(
            "HTTP/1.1 400 Bad Request\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Connection: close\r\n\r\n" +
            "Bad Request\n",
        );
        return;
    }

    const authenticated = isAuthenticated(clientRequest);
    const requestedToken = requestUrl.searchParams.get("token");
    if (!authenticated && (requestedToken === null || requestedToken.length === 0)) {
        clientSocket.end(
            "HTTP/1.1 401 Unauthorized\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Connection: close\r\n\r\n" +
            "Authentication required.\n",
        );
        return;
    }

    const translated = translateRequestUrl(clientRequest.url, {
        authenticated,
        hasSession: hasDshSession(clientRequest),
        allowAutoInject: false,
    });
    if (translated.tokenError) {
        clientSocket.end(
            "HTTP/1.1 503 Service Unavailable\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Retry-After: 2\r\n" +
            "Connection: close\r\n\r\n" +
            "DeepSeek Harness token is not ready. Retry in a moment.\n",
        );
        return;
    }

    const upstreamSocket = net.connect(UPSTREAM_PORT, UPSTREAM_HOST, () => {
        // 手工构造 Upgrade 请求行和请求头，使用改写后的 Host，并移除 Origin。
        const lines = [
            `${clientRequest.method} ${translated.url} HTTP/${clientRequest.httpVersion}`,
        ];

        for (const [name, value] of Object.entries(
            forwardHeaders(clientRequest.headers, { preserveUpgrade: true }),
        )) {
            if (Array.isArray(value)) {
                for (const item of value) lines.push(`${name}: ${item}`);
            } else if (value !== undefined) {
                lines.push(`${name}: ${value}`);
            }
        }

        upstreamSocket.write(`${lines.join("\r\n")}\r\n\r\n`);
        if (head && head.length > 0) upstreamSocket.write(head);

        upstreamSocket.pipe(clientSocket);
        clientSocket.pipe(upstreamSocket);
    });

    upstreamSocket.on("error", (error) => {
        console.error(`dsh-proxy: websocket upstream failed: ${error.message}`);
        clientSocket.destroy();
    });

    // 客户端断开时关闭上游连接。
    // 上游正常结束时由 pipe() 向客户端发送 FIN，不能立刻 destroy 客户端，
    // 否则最后一个 101 响应或数据帧可能还没送达浏览器。
    clientSocket.on("close", () => upstreamSocket.destroy());
});

// 记录活动连接，使收到 SIGTERM 时可以立即关闭长连接。
// Supervisor 停止服务时会发送 SIGTERM。
const activeSockets = new Set();

server.on("connection", (socket) => {
    activeSockets.add(socket);
    socket.on("close", () => activeSockets.delete(socket));
});

server.requestTimeout = 0;       // 支持长时间 SSE 和流式响应。
server.headersTimeout = 60_000;  // 限制请求头读取时间。
server.keepAliveTimeout = 65_000;

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
    console.log(`dsh-proxy: listening on ${LISTEN_HOST}:${LISTEN_PORT} -> ${UPSTREAM_AUTHORITY}`);
});

function shutdown(signal) {
    console.log(`dsh-proxy: received ${signal}, shutting down`);
    server.close();
    for (const socket of activeSockets) socket.destroy();
    process.exit(0);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
