'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const path = require('node:path');
const { createReadStream, readFileSync } = require('node:fs');
const fs = require('node:fs/promises');

const PORT = Number(process.env.PORT || 3000);
const DATA_DIR = process.env.DATA_DIR || '/data';
const UPLOAD_DIR = path.join(DATA_DIR, '.uploads');
const AUTH_USER = process.env.AUTH_USER || '';
const AUTH_PASSWORD_HASH = process.env.AUTH_PASSWORD_HASH || '';
const PUBLIC_URL = (process.env.PUBLIC_URL || '').replace(/\/+$/, '');
const MAX_SINGLE_UPLOAD = Number(process.env.MAX_SINGLE_UPLOAD || 95 * 1024 * 1024);
const MAX_CHUNK_SIZE = Number(process.env.MAX_CHUNK_SIZE || 16 * 1024 * 1024);
const WRITE_BATCH_SIZE = Number(process.env.WRITE_BATCH_SIZE || 4 * 1024 * 1024);
const FAILED_AUTH_LIMIT = 10;
const FAILED_AUTH_WINDOW_MS = 15 * 60 * 1000;
const failedAuth = new Map();
const CLIENT_ZSH = readFileSync(path.join(__dirname, 'client.zsh'), 'utf8').replaceAll('__TUNNELPANE_URL__', PUBLIC_URL);
const CLIENT_POWERSHELL = readFileSync(path.join(__dirname, 'client.ps1'), 'utf8').replaceAll('__TUNNELPANE_URL__', PUBLIC_URL);
const FAVICON_SVG = readFileSync(path.join(__dirname, 'assets', 'favicon.svg'));
const FAVICON_PNG = readFileSync(path.join(__dirname, 'assets', 'favicon-32.png'));
const APPLE_TOUCH_ICON = readFileSync(path.join(__dirname, 'assets', 'apple-touch-icon.png'));

if (!AUTH_USER) throw new Error('AUTH_USER is required');
try {
  const publicUrl = new URL(PUBLIC_URL);
  if (!['http:', 'https:'].includes(publicUrl.protocol)) throw new Error();
} catch {
  throw new Error('PUBLIC_URL must be an absolute HTTP or HTTPS URL');
}

if (!/^[a-f0-9]{64}$/i.test(AUTH_PASSWORD_HASH)) {
  throw new Error('AUTH_PASSWORD_HASH must be a SHA-256 hex digest');
}

const MIME_TYPES = new Map([
  ['.txt', 'text/plain; charset=utf-8'],
  ['.md', 'text/markdown; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.csv', 'text/csv; charset=utf-8'],
  ['.pdf', 'application/pdf'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.gif', 'image/gif'],
  ['.webp', 'image/webp'],
  ['.svg', 'image/svg+xml'],
  ['.zip', 'application/zip'],
  ['.gz', 'application/gzip'],
  ['.mp3', 'audio/mpeg'],
  ['.mp4', 'video/mp4'],
  ['.webm', 'video/webm'],
]);

const HTML = readFileSync(path.join(__dirname, 'client.html'), 'utf8');

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

const AUTH_USER_DIGEST = Buffer.from(sha256(AUTH_USER));
const AUTH_PASSWORD_DIGEST = Buffer.from(AUTH_PASSWORD_HASH.toLowerCase());

function pruneFailedAuth() {
  const now = Date.now();
  for (const [ip, state] of failedAuth) if (state.until <= now) failedAuth.delete(ip);
}

function json(res, status, payload, headers = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), ...headers });
  res.end(body);
}

function clientIp(req) {
  return String(req.headers['cf-connecting-ip'] || req.headers['x-forwarded-for'] || req.socket.remoteAddress || 'unknown').split(',')[0].trim();
}

function isAuthorized(req) {
  const ip = clientIp(req);
  const state = failedAuth.get(ip);
  if (state && state.until > Date.now() && state.count >= FAILED_AUTH_LIMIT) return false;

  const header = req.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  let decoded;
  try { decoded = Buffer.from(header.slice(6), 'base64').toString('utf8'); } catch { return false; }
  const separator = decoded.indexOf(':');
  if (separator < 0) return false;
  const user = decoded.slice(0, separator);
  const passwordHash = sha256(decoded.slice(separator + 1));
  const userOk = crypto.timingSafeEqual(Buffer.from(sha256(user)), AUTH_USER_DIGEST);
  const passOk = crypto.timingSafeEqual(Buffer.from(passwordHash), AUTH_PASSWORD_DIGEST);
  if (userOk && passOk) { failedAuth.delete(ip); return true; }

  const current = state && state.until > Date.now() ? state : { count: 0, until: Date.now() + FAILED_AUTH_WINDOW_MS };
  current.count += 1;
  failedAuth.set(ip, current);
  return false;
}

function challenge(res) {
  res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="TunnelPane", charset="UTF-8"', 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Authentication required\n');
}

function securityHeaders() {
  return {
    'Cache-Control': 'private, no-store',
    'Content-Security-Policy': "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
  };
}

function formatBytes(value) {
  if (!value) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
  return `${(value / (1024 ** index)).toFixed(index ? 1 : 0)} ${units[index]}`;
}

function validFilename(name) {
  return typeof name === 'string' && name.length > 0 && Buffer.byteLength(name) <= 240 && name !== '.' && name !== '..' && !name.startsWith('.') && !name.includes('/') && !name.includes('\\') && !name.includes('\0');
}

function validRelativePath(value) {
  return typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= 2048 && value.split('/').every(validFilename);
}

function storagePath(relativePath) {
  if (!validRelativePath(relativePath)) return null;
  const target = path.resolve(DATA_DIR, ...relativePath.split('/'));
  const root = path.resolve(DATA_DIR) + path.sep;
  return target.startsWith(root) ? target : null;
}

function filenameFromPath(pathname) {
  try {
    const name = decodeURIComponent(pathname.slice(1));
    return validRelativePath(name) ? name : null;
  } catch { return null; }
}

function fileId(name) {
  return Buffer.from(name, 'utf8').toString('base64url');
}

function filenameFromId(id) {
  if (!/^[A-Za-z0-9_-]+$/.test(id)) return null;
  try {
    const name = Buffer.from(id, 'base64url').toString('utf8');
    return validRelativePath(name) && fileId(name) === id ? name : null;
  } catch { return null; }
}

function cliFileIdFromPath(pathname) {
  const match = pathname.match(/^\/api\/cli\/files\/([A-Za-z0-9_-]+)$/);
  return match ? match[1] : null;
}

function cliFolderIdFromPath(pathname) {
  const match = pathname.match(/^\/api\/cli\/folders\/([A-Za-z0-9_-]+)$/);
  return match ? match[1] : null;
}

function parallelUploadRoute(pathname) {
  let match = pathname.match(/^\/api\/cli\/uploads\/([A-Za-z0-9_-]+)$/);
  if (match) return { action: 'start', fileId: match[1] };
  match = pathname.match(/^\/api\/cli\/uploads\/([a-f0-9-]{36})\/parts\/(\d+)$/);
  if (match) return { action: 'part', sessionId: match[1], partIndex: Number(match[2]) };
  match = pathname.match(/^\/api\/cli\/uploads\/([a-f0-9-]{36})\/(finish)$/);
  if (match) return { action: 'finish', sessionId: match[1] };
  match = pathname.match(/^\/api\/cli\/uploads\/([a-f0-9-]{36})$/);
  if (match) return { action: 'session', sessionId: match[1] };
  return null;
}

function uploadIdFromPath(pathname, suffix = '') {
  const pattern = suffix ? new RegExp('^/api/uploads/([a-f0-9-]{36})/' + suffix + '$') : /^\/api\/uploads\/([a-f0-9-]{36})$/;
  const match = pathname.match(pattern);
  return match ? match[1] : null;
}

async function readJson(req, maxBytes = 8192) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) throw Object.assign(new Error('Request body too large'), { status: 413 });
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw Object.assign(new Error('Invalid JSON'), { status: 400 }); }
}

async function writeRequest(req, target, flags, maxBytes) {
  const handle = await fs.open(target, flags, 0o600);
  let total = 0;
  try {
    for await (const chunk of req) {
      total += chunk.length;
      if (total > maxBytes) throw Object.assign(new Error('Upload chunk is too large'), { status: 413 });
      await handle.write(chunk);
    }
    return total;
  } finally {
    await handle.close();
  }
}

// Streams the request body straight into an existing file at a fixed offset.
// Concurrent callers may target the same file as long as their ranges differ.
// Socket chunks arrive around 64 KB, so they are gathered into WRITE_BATCH_SIZE
// batches and flushed with a single positional writev instead of one write each.
async function writeRequestAt(req, target, position, maxBytes) {
  const handle = await fs.open(target, 'r+');
  let total = 0;
  let pending = [];
  let pendingBytes = 0;
  try {
    const flush = async () => {
      if (!pendingBytes) return;
      await handle.writev(pending, position + total);
      total += pendingBytes;
      pending = [];
      pendingBytes = 0;
    };
    for await (const chunk of req) {
      if (total + pendingBytes + chunk.length > maxBytes) throw Object.assign(new Error('Upload chunk is too large'), { status: 413 });
      pending.push(chunk);
      pendingBytes += chunk.length;
      if (pendingBytes >= WRITE_BATCH_SIZE) await flush();
    }
    await flush();
    return total;
  } finally {
    await handle.close();
  }
}

// Parts are written into a file already sized by truncate, so no metadata
// change needs flushing and fdatasync is enough.
async function syncFile(target) {
  const handle = await fs.open(target, 'r+');
  try { await handle.datasync(); } finally { await handle.close(); }
}

async function listDirectory(relativePath = '') {
  const directory = relativePath ? storagePath(relativePath) : DATA_DIR;
  if (!directory) throw Object.assign(new Error('Invalid directory'), { status: 400 });
  let entries;
  try { entries = await fs.readdir(directory, { withFileTypes: true }); } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') throw Object.assign(new Error('Directory not found'), { status: 404 });
    throw error;
  }
  const visible = entries.filter(entry => !entry.name.startsWith('.') && (entry.isFile() || entry.isDirectory()) && validFilename(entry.name));
  const items = await Promise.all(visible.map(async entry => {
    const relative = relativePath ? `${relativePath}/${entry.name}` : entry.name;
    const stat = await fs.stat(path.join(directory, entry.name));
    return { id: fileId(relative), name: entry.name, path: relative, type: entry.isDirectory() ? 'dir' : 'file', size: entry.isFile() ? stat.size : 0, modified: stat.mtimeMs };
  }));
  return items.sort((a, b) => (a.type === b.type ? a.name.localeCompare(b.name) : a.type === 'dir' ? -1 : 1));
}

async function serveFile(req, res, name) {
  const target = storagePath(name);
  let stat;
  try { stat = await fs.stat(target); } catch (error) {
    if (error.code === 'ENOENT') return json(res, 404, { error: 'File not found' }, securityHeaders());
    throw error;
  }
  if (!stat.isFile()) return json(res, 404, { error: 'File not found' }, securityHeaders());

  const headers = {
    ...securityHeaders(),
    'Accept-Ranges': 'bytes',
    'Content-Type': MIME_TYPES.get(path.extname(name).toLowerCase()) || 'application/octet-stream',
    'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(path.basename(name))}`,
    'Last-Modified': stat.mtime.toUTCString(),
  };
  let start = 0;
  let end = stat.size - 1;
  let status = 200;
  if (req.headers.range) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range);
    if (!match) { res.writeHead(416, { ...headers, 'Content-Range': `bytes */${stat.size}` }); return res.end(); }
    if (match[1] === '' && match[2] !== '') {
      const suffix = Number(match[2]);
      start = Math.max(0, stat.size - suffix);
    } else {
      start = Number(match[1]);
      end = match[2] ? Math.min(Number(match[2]), stat.size - 1) : end;
    }
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= stat.size) {
      res.writeHead(416, { ...headers, 'Content-Range': `bytes */${stat.size}` }); return res.end();
    }
    status = 206;
    headers['Content-Range'] = `bytes ${start}-${end}/${stat.size}`;
  }
  headers['Content-Length'] = Math.max(0, end - start + 1);
  res.writeHead(status, headers);
  if (req.method === 'HEAD' || stat.size === 0) return res.end();
  createReadStream(target, { start, end, highWaterMark: 1024 * 1024 }).pipe(res);
}

async function startUpload(req, res) {
  const body = await readJson(req);
  if (!validRelativePath(body.filename)) return json(res, 400, { error: 'Invalid filename' }, securityHeaders());
  if (!Number.isSafeInteger(body.size) || body.size < 0) return json(res, 400, { error: 'Invalid file size' }, securityHeaders());
  const id = crypto.randomUUID();
  const part = path.join(UPLOAD_DIR, id + '.part');
  const meta = path.join(UPLOAD_DIR, id + '.json');
  await fs.writeFile(part, '', { flag: 'wx', mode: 0o600 });
  await fs.writeFile(meta, JSON.stringify({ filename: body.filename, size: body.size, createdAt: Date.now() }), { flag: 'wx', mode: 0o600 });
  json(res, 201, { id, offset: 0 }, securityHeaders());
}

async function readUpload(id) {
  const metaPath = path.join(UPLOAD_DIR, id + '.json');
  const partPath = path.join(UPLOAD_DIR, id + '.part');
  let metadata;
  try { metadata = JSON.parse(await fs.readFile(metaPath, 'utf8')); } catch (error) {
    if (error.code === 'ENOENT') throw Object.assign(new Error('Upload session not found'), { status: 404 });
    throw error;
  }
  return { metadata, metaPath, partPath };
}

async function appendUpload(req, res, id) {
  const upload = await readUpload(id);
  const stat = await fs.stat(upload.partPath);
  const offset = Number(req.headers['upload-offset']);
  if (!Number.isSafeInteger(offset) || offset !== stat.size) return json(res, 409, { error: 'Upload offset mismatch', offset: stat.size }, securityHeaders());
  const contentLength = Number(req.headers['content-length']);
  if (Number.isFinite(contentLength) && contentLength > MAX_CHUNK_SIZE) return json(res, 413, { error: 'Upload chunk is too large' }, securityHeaders());
  if (stat.size + Math.max(0, contentLength || 0) > upload.metadata.size) return json(res, 400, { error: 'Upload exceeds declared file size' }, securityHeaders());
  const written = await writeRequest(req, upload.partPath, 'a', Math.min(MAX_CHUNK_SIZE, upload.metadata.size - stat.size));
  json(res, 200, { offset: stat.size + written }, securityHeaders());
}

async function finishUpload(res, id) {
  const upload = await readUpload(id);
  const stat = await fs.stat(upload.partPath);
  if (stat.size !== upload.metadata.size) return json(res, 409, { error: 'Upload is incomplete', offset: stat.size, expected: upload.metadata.size }, securityHeaders());
  const target = storagePath(upload.metadata.filename);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await syncFile(upload.partPath);
  await fs.rename(upload.partPath, target);
  await fs.unlink(upload.metaPath);
  json(res, 200, { ok: true, name: upload.metadata.filename, size: stat.size }, securityHeaders());
}

async function directUpload(req, res, name) {
  const contentLength = Number(req.headers['content-length']);
  if (Number.isFinite(contentLength) && contentLength > MAX_SINGLE_UPLOAD) {
    return json(res, 413, { error: 'Direct uploads are limited to 95 MB; use the browser for larger files' }, securityHeaders());
  }
  const temp = path.join(UPLOAD_DIR, crypto.randomUUID() + '.put');
  try {
    const size = await writeRequest(req, temp, 'wx', MAX_SINGLE_UPLOAD);
    const target = storagePath(name);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await syncFile(temp);
    await fs.rename(temp, target);
    json(res, 201, { ok: true, name, size }, securityHeaders());
  } catch (error) {
    await fs.rm(temp, { force: true });
    throw error;
  }
}

function parallelMetaPath(id) {
  return path.join(UPLOAD_DIR, `.parallel-${id}.json`);
}

function parallelDataPath(id) {
  return path.join(UPLOAD_DIR, `.parallel-${id}.data`);
}

// Zero-byte marker recording that a part landed; the payload itself already
// sits at its final offset inside the session's data file.
function parallelPartPath(id, index) {
  return path.join(UPLOAD_DIR, `.parallel-${id}-${String(index).padStart(6, '0')}.part`);
}

async function readParallelUpload(id) {
  try {
    const metadata = JSON.parse(await fs.readFile(parallelMetaPath(id), 'utf8'));
    return metadata;
  } catch (error) {
    if (error.code === 'ENOENT') throw Object.assign(new Error('Upload session not found'), { status: 404 });
    throw error;
  }
}

async function startParallelUpload(req, res, url, fileIdValue) {
  const filename = filenameFromId(fileIdValue);
  const size = Number(url.searchParams.get('size'));
  const requestedPartSize = Number(url.searchParams.get('partSize') || 8 * 1024 * 1024);
  if (!filename) return json(res, 400, { error: 'Invalid file ID' }, securityHeaders());
  if (!Number.isSafeInteger(size) || size < 0) return json(res, 400, { error: 'Invalid file size' }, securityHeaders());
  const minimumPartSize = Math.min(1024 * 1024, MAX_CHUNK_SIZE);
  if (!Number.isSafeInteger(requestedPartSize) || requestedPartSize < minimumPartSize || requestedPartSize > MAX_CHUNK_SIZE) {
    return json(res, 400, { error: 'Invalid part size' }, securityHeaders());
  }
  const partCount = Math.max(1, Math.ceil(size / requestedPartSize));
  if (partCount > 100000) return json(res, 413, { error: 'Upload requires too many parts' }, securityHeaders());
  const id = crypto.randomUUID();
  const metadata = { id, filename, size, partSize: requestedPartSize, partCount, createdAt: Date.now() };
  const data = await fs.open(parallelDataPath(id), 'wx', 0o600);
  try { await data.truncate(size); } finally { await data.close(); }
  await fs.writeFile(parallelMetaPath(id), JSON.stringify(metadata), { flag: 'wx', mode: 0o600 });
  if (url.searchParams.get('format') === 'tsv') {
    const body = [id, requestedPartSize, partCount].join('\t') + '\n';
    res.writeHead(201, { ...securityHeaders(), 'Content-Type': 'text/tab-separated-values; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
    return res.end(body);
  }
  return json(res, 201, metadata, securityHeaders());
}

async function uploadParallelPart(req, res, id, index) {
  const metadata = await readParallelUpload(id);
  if (!Number.isSafeInteger(index) || index < 0 || index >= metadata.partCount) {
    return json(res, 400, { error: 'Invalid part index' }, securityHeaders());
  }
  const expected = index === metadata.partCount - 1 ? metadata.size - index * metadata.partSize : metadata.partSize;
  const contentLength = Number(req.headers['content-length']);
  if (Number.isFinite(contentLength) && contentLength !== expected) {
    return json(res, 400, { error: 'Part size does not match expected size', expected }, securityHeaders());
  }
  const written = await writeRequestAt(req, parallelDataPath(id), index * metadata.partSize, expected);
  if (written !== expected) return json(res, 400, { error: 'Part size does not match expected size', expected, written }, securityHeaders());
  await fs.writeFile(parallelPartPath(id, index), '', { mode: 0o600 });
  return json(res, 201, { ok: true, index, size: written }, securityHeaders());
}

async function removeParallelUpload(id, metadata) {
  const upload = metadata || await readParallelUpload(id);
  await Promise.all(Array.from({ length: upload.partCount }, (_, index) => fs.rm(parallelPartPath(id, index), { force: true })));
  await fs.rm(parallelDataPath(id), { force: true });
  await fs.rm(parallelMetaPath(id), { force: true });
}

async function finishParallelUpload(res, id) {
  const metadata = await readParallelUpload(id);
  const data = parallelDataPath(id);
  for (let index = 0; index < metadata.partCount; index++) {
    try { await fs.access(parallelPartPath(id, index)); } catch (error) {
      if (error.code === 'ENOENT') return json(res, 409, { error: 'Upload is incomplete', missingPart: index }, securityHeaders());
      throw error;
    }
  }

  const stat = await fs.stat(data);
  if (stat.size !== metadata.size) return json(res, 409, { error: 'Assembled upload size mismatch', size: stat.size, expected: metadata.size }, securityHeaders());
  // Parts were written without per-part fsync; flush once before publishing.
  await syncFile(data);
  const target = storagePath(metadata.filename);
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.rename(data, target);
  await removeParallelUpload(id, metadata);
  return json(res, 200, { ok: true, name: metadata.filename, size: metadata.size }, securityHeaders());
}

async function cleanupUploads() {
  const cutoff = Date.now() - 24 * 60 * 60 * 1000;
  for (const entry of await fs.readdir(UPLOAD_DIR, { withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const target = path.join(UPLOAD_DIR, entry.name);
    const stat = await fs.stat(target);
    if (stat.mtimeMs < cutoff) await fs.rm(target, { force: true });
  }
}

async function handle(req, res) {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/healthz') return json(res, 200, { ok: true });
  if (req.method === 'GET' && url.pathname === '/client.zsh') {
    res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': Buffer.byteLength(CLIENT_ZSH) });
    return res.end(CLIENT_ZSH);
  }
  if (req.method === 'GET' && url.pathname === '/client.ps1') {
    res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': Buffer.byteLength(CLIENT_POWERSHELL) });
    return res.end(CLIENT_POWERSHELL);
  }
  if (req.method === 'GET' && url.pathname === '/favicon.svg') {
    res.writeHead(200, { ...securityHeaders(), 'Cache-Control': 'public, max-age=604800', 'Content-Type': 'image/svg+xml', 'Content-Length': FAVICON_SVG.length });
    return res.end(FAVICON_SVG);
  }
  if (req.method === 'GET' && (url.pathname === '/favicon-32.png' || url.pathname === '/favicon.ico')) {
    res.writeHead(200, { ...securityHeaders(), 'Cache-Control': 'public, max-age=604800', 'Content-Type': 'image/png', 'Content-Length': FAVICON_PNG.length });
    return res.end(FAVICON_PNG);
  }
  if (req.method === 'GET' && url.pathname === '/apple-touch-icon.png') {
    res.writeHead(200, { ...securityHeaders(), 'Cache-Control': 'public, max-age=604800', 'Content-Type': 'image/png', 'Content-Length': APPLE_TOUCH_ICON.length });
    return res.end(APPLE_TOUCH_ICON);
  }
  if (!isAuthorized(req)) return challenge(res);

  if (req.method === 'GET' && url.pathname === '/') {
    res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(HTML) });
    return res.end(HTML);
  }
  if (req.method === 'GET' && url.pathname === '/api/files') {
    const directory = url.searchParams.get('path') || '';
    if (directory && !validRelativePath(directory)) return json(res, 400, { error: 'Invalid directory' }, securityHeaders());
    return json(res, 200, { path: directory, files: await listDirectory(directory) }, securityHeaders());
  }
  if (req.method === 'GET' && url.pathname === '/api/cli/files') {
    const directoryId = url.searchParams.get('path');
    const directory = directoryId ? filenameFromId(directoryId) : '';
    if (directoryId && !directory) return json(res, 400, { error: 'Invalid directory' }, securityHeaders());
    const files = await listDirectory(directory);
    const regularFiles = files.filter(file => file.type === 'file');
    if (url.searchParams.get('format') === 'tsv') {
      const body = regularFiles.map(file => [file.id, Buffer.from(file.name).toString('base64'), formatBytes(file.size), new Date(file.modified).toISOString()].join('\t')).join('\n') + (regularFiles.length ? '\n' : '');
      res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/tab-separated-values; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
      return res.end(body);
    }
    if (url.searchParams.get('format') === 'tsv2') {
      const body = regularFiles.map(file => [file.id, Buffer.from(file.name).toString('base64'), formatBytes(file.size), new Date(file.modified).toISOString(), file.size].join('\t')).join('\n') + (regularFiles.length ? '\n' : '');
      res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/tab-separated-values; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
      return res.end(body);
    }
    if (url.searchParams.get('format') === 'tsv3') {
      const body = files.map(file => [file.id, Buffer.from(file.name).toString('base64'), file.type, file.type === 'dir' ? '-' : formatBytes(file.size), new Date(file.modified).toISOString(), file.size].join('\t')).join('\n') + (files.length ? '\n' : '');
      res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/tab-separated-values; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
      return res.end(body);
    }
    if (url.searchParams.get('format') === 'json3') {
      return json(res, 200, { path: directory, files: files.map(file => ({ ...file, sizeLabel: file.type === 'dir' ? '-' : formatBytes(file.size) })) }, securityHeaders());
    }
    return json(res, 200, { files: regularFiles.map(file => ({ ...file, sizeLabel: formatBytes(file.size) })) }, securityHeaders());
  }
  if (req.method === 'GET' && url.pathname === '/api/status') {
    const disk = await fs.statfs(DATA_DIR);
    const total = disk.blocks * disk.bsize;
    const free = disk.bavail * disk.bsize;
    return json(res, 200, { total, free, used: total - free }, securityHeaders());
  }
  if (req.method === 'POST' && url.pathname === '/api/uploads') return startUpload(req, res);
  const uploadId = uploadIdFromPath(url.pathname);
  if (req.method === 'PATCH' && uploadId) return appendUpload(req, res, uploadId);
  const finishId = uploadIdFromPath(url.pathname, 'finish');
  if (req.method === 'POST' && finishId) return finishUpload(res, finishId);

  const parallelRoute = parallelUploadRoute(url.pathname);
  if (parallelRoute) {
    if (req.method === 'POST' && parallelRoute.action === 'start') return startParallelUpload(req, res, url, parallelRoute.fileId);
    if (req.method === 'DELETE' && parallelRoute.action === 'start' && /^[a-f0-9-]{36}$/.test(parallelRoute.fileId)) {
      await removeParallelUpload(parallelRoute.fileId);
      return json(res, 200, { ok: true }, securityHeaders());
    }
    if (req.method === 'PUT' && parallelRoute.action === 'part') return uploadParallelPart(req, res, parallelRoute.sessionId, parallelRoute.partIndex);
    if (req.method === 'POST' && parallelRoute.action === 'finish') return finishParallelUpload(res, parallelRoute.sessionId);
    if (req.method === 'DELETE' && parallelRoute.action === 'session') {
      await removeParallelUpload(parallelRoute.sessionId);
      return json(res, 200, { ok: true }, securityHeaders());
    }
    return json(res, 405, { error: 'Method not allowed' }, securityHeaders());
  }

  const cliId = cliFileIdFromPath(url.pathname);
  if (cliId) {
    const cliName = filenameFromId(cliId);
    if (!cliName) return json(res, 400, { error: 'Invalid file ID' }, securityHeaders());
    if (req.method === 'GET' || req.method === 'HEAD') return serveFile(req, res, cliName);
    if (req.method === 'PUT') return directUpload(req, res, cliName);
    if (req.method === 'DELETE') {
      try { await fs.rm(storagePath(cliName), { recursive: true }); } catch (error) {
        if (error.code === 'ENOENT') return json(res, 404, { error: 'File not found' }, securityHeaders());
        throw error;
      }
      return json(res, 200, { ok: true }, securityHeaders());
    }
    return json(res, 405, { error: 'Method not allowed' }, { ...securityHeaders(), Allow: 'GET, HEAD, PUT, DELETE' });
  }

  const folderId = cliFolderIdFromPath(url.pathname);
  if (folderId) {
    const folder = filenameFromId(folderId);
    if (!folder) return json(res, 400, { error: 'Invalid folder path' }, securityHeaders());
    if (req.method === 'POST') {
      await fs.mkdir(storagePath(folder), { recursive: true, mode: 0o700 });
      return json(res, 201, { ok: true, path: folder }, securityHeaders());
    }
    return json(res, 405, { error: 'Method not allowed' }, { ...securityHeaders(), Allow: 'POST' });
  }

  const name = filenameFromPath(url.pathname);
  if (!name) return json(res, 404, { error: 'Not found' }, securityHeaders());
  if (req.method === 'GET' || req.method === 'HEAD') return serveFile(req, res, name);
  if (req.method === 'PUT') return directUpload(req, res, name);
  if (req.method === 'DELETE') {
    try { await fs.rm(storagePath(name), { recursive: true }); } catch (error) {
      if (error.code === 'ENOENT') return json(res, 404, { error: 'File not found' }, securityHeaders());
      throw error;
    }
    return json(res, 200, { ok: true }, securityHeaders());
  }
  json(res, 405, { error: 'Method not allowed' }, { ...securityHeaders(), Allow: 'GET, HEAD, PUT, DELETE' });
}

async function main() {
  await fs.mkdir(DATA_DIR, { recursive: true });
  await fs.mkdir(UPLOAD_DIR, { recursive: true, mode: 0o700 });
  await cleanupUploads();
  setInterval(() => {
    pruneFailedAuth();
    cleanupUploads().catch(error => console.error('upload cleanup failed', error));
  }, 60 * 60 * 1000).unref();
  const server = http.createServer((req, res) => {
    handle(req, res).catch(error => {
      // A cancelled upload aborts its request mid-body; that is routine, not a fault.
      const aborted = req.destroyed || req.aborted || ['ECONNRESET', 'ERR_STREAM_PREMATURE_CLOSE'].includes(error.code);
      if (aborted) return res.destroy();
      if (!error.status || error.status >= 500) console.error(req.method, req.url, error);
      if (!res.headersSent) json(res, error.status || 500, { error: error.status ? error.message : 'Internal server error' }, securityHeaders());
      else res.destroy();
    });
  });
  server.requestTimeout = 30 * 60 * 1000;
  server.headersTimeout = 30 * 1000;
  server.listen(PORT, '0.0.0.0', () => console.log(`TunnelPane listening on ${PORT}`));
}

main().catch(error => { console.error(error); process.exit(1); });
