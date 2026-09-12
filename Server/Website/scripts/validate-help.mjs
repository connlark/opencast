#!/usr/bin/env node
// Validates the app help document (public/app/help/v1.json) against the
// contract the iOS app decodes: schema version, second-precision ISO 8601
// dates, unique slug ids, resolvable related ids, per-block required fields,
// and https:/mailto: links on known public hosts only. No dependencies.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const websiteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const documentPath = path.join(websiteDir, "public", "app", "help", "v1.json");

const SUPPORTED_SCHEMA_VERSION = 1;
const ISO_8601_SECONDS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
// Fail closed: link targets must be hosts the public repository may name.
const PUBLIC_LINK_HOSTS = new Set(["support.opencast.mobile", "opencast.mobile", "github.com", "apple.com"]);
const BLOCK_FIELDS = {
  heading: ["text"],
  paragraph: ["text"],
  bullets: ["items"],
  callout: ["symbol", "text"],
  link: ["title", "url"],
};

const errors = [];
const fail = (message) => errors.push(message);
const nonEmptyString = (value) => typeof value === "string" && value.trim().length > 0;

function isPublicHost(hostname) {
  if (PUBLIC_LINK_HOSTS.has(hostname)) return true;
  return hostname.endsWith(".apple.com");
}

function checkLink(where, value) {
  if (!nonEmptyString(value)) return fail(`${where}: url must be a non-empty string`);
  let url;
  try {
    url = new URL(value);
  } catch {
    return fail(`${where}: url is not absolute (${value})`);
  }
  if (url.protocol === "mailto:") return;
  if (url.protocol !== "https:") return fail(`${where}: url must use https: or mailto: (${value})`);
  if (!isPublicHost(url.hostname)) return fail(`${where}: host ${url.hostname} is not a public host`);
}

function checkBlock(where, block) {
  if (typeof block !== "object" || block === null) return fail(`${where}: block must be an object`);
  if (!nonEmptyString(block.type)) return fail(`${where}: block.type is required`);
  const required = BLOCK_FIELDS[block.type];
  if (!required) return fail(`${where}: unknown block type "${block.type}"`);
  for (const field of required) {
    if (field === "items") {
      if (!Array.isArray(block.items) || block.items.length === 0 || !block.items.every(nonEmptyString)) {
        fail(`${where}: bullets.items must be a non-empty array of strings`);
      }
    } else if (!nonEmptyString(block[field])) {
      fail(`${where}: ${block.type}.${field} is required`);
    }
  }
  if (block.type === "link") checkLink(where, block.url);
  if (block.type === "callout" && block.title !== undefined && !nonEmptyString(block.title)) {
    fail(`${where}: callout.title must be a non-empty string when present`);
  }
}

function checkDate(where, value) {
  if (!ISO_8601_SECONDS.test(String(value)) || Number.isNaN(Date.parse(value))) {
    fail(`${where}: expected a second-precision ISO 8601 UTC date, got ${JSON.stringify(value)}`);
  }
}

let document;
try {
  document = JSON.parse(readFileSync(documentPath, "utf8"));
} catch (error) {
  console.error(`validate-help: cannot read ${documentPath}: ${error.message}`);
  process.exit(1);
}

if (document.schemaVersion !== SUPPORTED_SCHEMA_VERSION) {
  fail(`schemaVersion must be ${SUPPORTED_SCHEMA_VERSION}`);
}
checkDate("updatedAt", document.updatedAt);
if (!Array.isArray(document.topics) || document.topics.length === 0) {
  fail("topics must be a non-empty array");
}

const ids = new Set();
for (const [index, topic] of (document.topics ?? []).entries()) {
  const where = `topics[${index}]`;
  if (!nonEmptyString(topic.id) || !SLUG.test(topic.id)) fail(`${where}: id must be a lowercase slug`);
  if (ids.has(topic.id)) fail(`${where}: duplicate id "${topic.id}"`);
  ids.add(topic.id);
  for (const field of ["title", "symbol", "summary"]) {
    if (!nonEmptyString(topic[field])) fail(`${where}: ${field} is required`);
  }
  checkDate(`${where}.updatedAt`, topic.updatedAt);
  if (topic.minAppBuild !== undefined && !(Number.isInteger(topic.minAppBuild) && topic.minAppBuild > 0)) {
    fail(`${where}: minAppBuild must be a positive integer when present`);
  }
  if (topic.related !== undefined && !(Array.isArray(topic.related) && topic.related.every(nonEmptyString))) {
    fail(`${where}: related must be an array of ids when present`);
  }
  if (!Array.isArray(topic.blocks) || topic.blocks.length === 0) {
    fail(`${where}: blocks must be a non-empty array`);
  } else {
    topic.blocks.forEach((block, blockIndex) => checkBlock(`${where}.blocks[${blockIndex}]`, block));
  }
}
for (const [index, topic] of (document.topics ?? []).entries()) {
  for (const related of topic.related ?? []) {
    if (!ids.has(related)) fail(`topics[${index}]: related id "${related}" does not exist`);
    if (related === topic.id) fail(`topics[${index}]: related must not reference itself`);
  }
}

if (errors.length > 0) {
  console.error(`validate-help: ${errors.length} problem(s) in ${path.relative(websiteDir, documentPath)}`);
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log(`validate-help: ${ids.size} topics OK (${document.updatedAt})`);
