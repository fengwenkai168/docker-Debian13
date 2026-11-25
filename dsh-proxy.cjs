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
// 该行为会绕过 dsh 针对恶意 Host 的额外防护，只应运行在可信网络中。

"use strict";

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

// 没有固定 token 就无法提供稳定的登录入口，直接让 Supervisor 报错并重启。
if (DSH_WEB_TOKEN.length === 0) {
    console.error("dsh-proxy: DSH_WEB_TOKEN is required");
    process.exit(1);
}

// 将浏览器 URL 中的固定 token 替换为 dsh 本次进程的真实随机 token。
// - 没有 token 参数时原样转发，让 dsh 自己处理 Cookie 登录或返回 401。
// - token 与 Compose 固定值不一致时也原样转发，避免代理掩盖错误凭据。
// - token 正确但捕获文件尚未生成时返回 tokenError，由调用方返回 503。
function translateRequestUrl(rawUrl) {
    let parsed;

    try {
        parsed = new URL(rawUrl, `http://${UPSTREAM_AUTHORITY}`);
    } catch {
        return { url: rawUrl, tokenError: false };
    }

    if (parsed.searchParams.get("token") !== DSH_WEB_TOKEN) {
        return { url: rawUrl, tokenError: false };
    }

    let actualToken;
    try {
        actualToken = fs.readFileSync(DSH_TOKEN_FILE, "utf8").trim();
    } catch {
        actualToken = "";
    }

    if (actualToken.length === 0) {
        return { url: rawUrl, tokenError: true };
    }

    parsed.searchParams.set("token", actualToken);
    return {
        url: `${parsed.pathname}${parsed.search}`,
        tokenError: false,
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

// 普通 HTTP 请求处理。
// 请求体通过管道直接流式转发，不把上传文件整体读入内存。
const server = http.createServer((clientRequest, clientResponse) => {
    const translated = translateRequestUrl(clientRequest.url);

    // dsh 可能刚启动，还没打印出真实 token。
    // 返回 503 而不是把固定 token 直接发给 dsh，避免得到难以理解的 401。
    if (translated.tokenError) {
        clientResponse.writeHead(503, {
            "content-type": "text/plain; charset=utf-8",
            "retry-after": "2",
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
            const responseHeaders = { ...upstreamResponse.headers };

            // 清理逐跳响应头，并修正可能指向容器回环地址的 Location。
            for (const name of Object.keys(responseHeaders)) {
                if (HOP_BY_HOP_HEADERS.has(name.toLowerCase())) {
                    delete responseHeaders[name];
                }
            }

            // 只有响应确实包含 Location 时才改写，避免把 undefined 写入响应头。
            if (responseHeaders.location !== undefined) {
                responseHeaders.location = rewriteLocation(responseHeaders.location);
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

    const translated = translateRequestUrl(clientRequest.url);
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
