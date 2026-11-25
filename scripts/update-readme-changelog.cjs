#!/usr/bin/env node
// 把一次镜像构建的更新日志写入 README.md。
//
// 用法：
//   node scripts/update-readme-changelog.cjs \
//     <image-changelog.md> <README.md> <release-tag>
//
// 输入：
// - image-changelog.md：write-image-changelog.sh 生成的实际版本清单。
// - README.md：包含 versions 和 changelog 两组 HTML 注释标记。
// - release-tag：本次构建的语义版本，例如 v0.0.1。
//
// 行为：
// - 用最新构建的实际版本表替换 README 顶部“当前工具版本”区域。
// - 在更新日志标记内按“最新在上”的顺序插入本次构建信息。
// - 保留历史构建记录。
// - 如果同一个 release-tag 已存在，则不重复追加构建记录。
// - 如果没有找到标记或输入段落，返回非零退出码，让 Actions 明确失败。

"use strict";

const fs = require("node:fs");

const [changelogPath, readmePath, releaseTag] = process.argv.slice(2);

if (!changelogPath || !readmePath || !releaseTag) {
    console.error(
        "用法: node scripts/update-readme-changelog.cjs " +
        "<image-changelog.md> <README.md> <release-tag>",
    );
    process.exit(1);
}

const VERSIONS_START_MARKER = "<!-- versions:start -->";
const VERSIONS_END_MARKER = "<!-- versions:end -->";
const START_MARKER = "<!-- changelog:start -->";
const END_MARKER = "<!-- changelog:end -->";
const PLACEHOLDER_PREFIX = "> 等待第一次 GitHub Actions 构建后自动写入更新日志。";

// 用 body 替换两个 HTML 注释标记之间的内容。
// versions 和 changelog 两个区域都使用此函数，确保标记完整且不会破坏其他文档。
function replaceMarkedSection(markdown, startMarker, endMarker, body, label) {
    const start = markdown.indexOf(startMarker);
    const end = markdown.indexOf(endMarker);

    if (start === -1 || end === -1 || end < start) {
        throw new Error(`README.md 中缺少有效的 ${label} 标记`);
    }

    return `${markdown.slice(0, start + startMarker.length)}\n${body.trim()}\n${markdown.slice(end)}`;
}

// 从完整更新日志中提取指定二级标题下的 Markdown 内容。
// 遇到下一个二级标题（## ）时结束，避免把部署说明等内容重复写入 README。
function extractSection(markdown, heading) {
    const marker = `## ${heading}`;
    const start = markdown.indexOf(marker);
    if (start === -1) {
        throw new Error(`更新日志中缺少段落: ${marker}`);
    }

    const afterHeading = markdown.slice(start + marker.length);
    const nextHeading = afterHeading.search(/\n## /);
    return (nextHeading === -1 ? afterHeading : afterHeading.slice(0, nextHeading)).trim();
}

// 从“构建信息”表格中读取构建时间，用作折叠条目的摘要。
// 如果格式变化，退回到当前时间，仍可生成有效 README。
function extractBuildTime(buildInfo) {
    const matched = buildInfo.match(/\|\s*构建时间\s*\|\s*`([^`]+)`\s*\|/);
    return matched ? matched[1] : new Date().toISOString();
}

const changelog = fs.readFileSync(changelogPath, "utf8");
const readme = fs.readFileSync(readmePath, "utf8");

const buildInfo = extractSection(changelog, "构建信息");
const installedVersions = extractSection(changelog, "实际安装版本");
const buildTime = extractBuildTime(buildInfo);

// GitHub README 支持 details/summary。每次构建折叠成一个条目，
// 默认不展开版本表，避免 README 首屏过长，同时保留所有历史记录。
const entry = [
    `<details>`,
    `<summary><strong>${releaseTag}</strong> · ${buildTime}</summary>`,
    "",
    buildInfo,
    "",
    installedVersions,
    "",
    `</details>`,
].join("\n");

// 先刷新“当前工具版本”表格，再处理历史更新日志。
let updatedReadme = replaceMarkedSection(
    readme,
    VERSIONS_START_MARKER,
    VERSIONS_END_MARKER,
    installedVersions,
    "versions:start / versions:end",
);

const startIndex = updatedReadme.indexOf(START_MARKER);
const endIndex = updatedReadme.indexOf(END_MARKER);

if (startIndex === -1 || endIndex === -1 || endIndex < startIndex) {
    throw new Error("README.md 中缺少有效的 changelog:start / changelog:end 标记");
}

const before = updatedReadme.slice(0, startIndex + START_MARKER.length);
const rawBetween = updatedReadme.slice(startIndex + START_MARKER.length, endIndex);
const after = updatedReadme.slice(endIndex);
const existing = rawBetween.trim();

// 同一个构建重复执行时保持幂等：不重复追加构建记录，
// 但“当前工具版本”表格仍可能已经刷新，因此需要判断是否写回。
if (existing.includes(`<strong>${releaseTag}</strong>`)) {
    if (updatedReadme !== readme) {
        fs.writeFileSync(readmePath, updatedReadme, "utf8");
        console.log(`README 已包含 ${releaseTag}，仅刷新当前工具版本表。`);
    } else {
        console.log(`README 更新日志已包含 ${releaseTag}，跳过。`);
    }
    process.exit(0);
}

// 第一次运行时删除占位提示；之后把新条目放在历史条目之前。
const previousEntries = existing.startsWith(PLACEHOLDER_PREFIX) ? "" : existing;
const merged = previousEntries.length > 0
    ? `${entry}\n\n${previousEntries}`
    : entry;

updatedReadme = `${before}\n${merged}\n${after}`;

if (updatedReadme === readme) {
    console.log("README 更新日志没有变化。");
    process.exit(0);
}

fs.writeFileSync(readmePath, updatedReadme, "utf8");
console.log(`已把 ${releaseTag} 写入 ${readmePath}`);
