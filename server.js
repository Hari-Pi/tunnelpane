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
const FAILED_AUTH_LIMIT = 10;
const FAILED_AUTH_WINDOW_MS = 15 * 60 * 1000;
const failedAuth = new Map();
const CLIENT_ZSH = readFileSync(path.join(__dirname, 'client.zsh'), 'utf8').replaceAll('__TUNNELPANE_URL__', PUBLIC_URL);
const CLIENT_POWERSHELL = readFileSync(path.join(__dirname, 'client.ps1'), 'utf8').replaceAll('__TUNNELPANE_URL__', PUBLIC_URL);

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

const HTML = String.raw`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>TunnelPane</title>
  <style>
    :root{color-scheme:light;--ink:#202522;--muted:#69716c;--line:#d9dedb;--soft:#f4f6f5;--green:#16835b;--green-dark:#0c6544;--blue:#2167c5;--red:#b52d3a;--white:#fff}
    *{box-sizing:border-box}body{margin:0;background:var(--white);color:var(--ink);font:15px/1.45 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;letter-spacing:0}
    button,input,select{font:inherit;letter-spacing:0}button{cursor:pointer}.shell{width:min(1120px,calc(100% - 32px));margin:0 auto}
    header{border-bottom:1px solid var(--line);background:#fff}.header-row{min-height:68px;display:flex;align-items:center;justify-content:space-between;gap:20px}
    .brand{font-size:21px;font-weight:750}.brand span{color:var(--green)}.storage{font-size:13px;color:var(--muted);text-align:right}
    main{padding:28px 0 48px}.upload-band{border:1px dashed #9daf9f;background:#f7faf8;padding:24px;text-align:center;border-radius:6px;transition:.15s}
    .upload-band.drag{border-color:var(--green);background:#eef8f3}.upload-band strong{display:block;font-size:17px;margin-bottom:4px}.upload-band p{margin:0 0 15px;color:var(--muted)}
    .primary,.secondary,.danger{border-radius:5px;padding:9px 14px;font-weight:650;border:1px solid transparent}.primary{background:var(--green);color:#fff}.primary:hover{background:var(--green-dark)}
    .secondary{background:#fff;border-color:var(--line);color:var(--ink)}.secondary:hover{background:var(--soft)}.danger{background:#fff;border-color:#e5b8bd;color:var(--red)}.danger:hover{background:#fff3f4}
    .queue{margin-top:14px;text-align:left}.job{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:7px 16px;padding:10px 0;border-top:1px solid var(--line)}
    .job-name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.job-status{color:var(--muted);font-size:13px}.progress{height:5px;background:#dde4df;grid-column:1/-1;border-radius:3px;overflow:hidden}.progress span{display:block;height:100%;background:var(--green);width:0}
    .toolbar{display:flex;align-items:center;gap:10px;margin:26px 0 12px}.search{flex:1;min-width:0;border:1px solid var(--line);border-radius:5px;padding:9px 11px}.sort{border:1px solid var(--line);border-radius:5px;padding:9px 32px 9px 10px;background:#fff}
    .table-wrap{border:1px solid var(--line);border-radius:6px;overflow:hidden}table{width:100%;border-collapse:collapse;table-layout:fixed}th{background:var(--soft);color:var(--muted);font-size:12px;text-transform:uppercase;text-align:left;padding:10px 12px}td{padding:12px;border-top:1px solid var(--line);vertical-align:middle}
    th:nth-child(1){width:52%}th:nth-child(2){width:14%}th:nth-child(3){width:18%}th:nth-child(4){width:16%}.file-name{font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-name a{color:var(--ink);text-decoration:none}.file-name a:hover{color:var(--blue);text-decoration:underline}
    .actions{display:flex;justify-content:flex-end;gap:7px}.icon-action{border:0;background:transparent;color:var(--blue);padding:5px}.icon-action.delete{color:var(--red)}.empty{padding:42px 20px;text-align:center;color:var(--muted)}
    .notice{position:fixed;right:20px;bottom:20px;max-width:min(390px,calc(100% - 40px));background:#242a26;color:#fff;padding:11px 14px;border-radius:5px;box-shadow:0 8px 28px #0003;display:none}.notice.error{background:#8f2430}
    @media(max-width:720px){.shell{width:min(100% - 20px,1120px)}.header-row{min-height:60px}.storage{display:none}main{padding-top:18px}.upload-band{padding:20px 14px}.toolbar{flex-wrap:wrap}.search{flex-basis:100%}.sort{flex:1}.table-wrap{border-left:0;border-right:0;border-radius:0}th:nth-child(2),td:nth-child(2),th:nth-child(3),td:nth-child(3){display:none}th:nth-child(1){width:58%}th:nth-child(4){width:42%}td{padding:11px 8px}.actions{gap:2px}.icon-action{padding:6px 4px;font-size:13px}}
  </style>
</head>
<body>
  <header><div class="shell header-row"><div class="brand">Tunnel<span>Pane</span></div><div class="storage" id="storage">Checking storage...</div></div></header>
  <main class="shell">
    <section class="upload-band" id="dropZone">
      <strong>Upload files</strong><p>Drop files here or choose them from your device.</p>
      <button class="primary" id="chooseButton" type="button">Choose files</button><input id="fileInput" type="file" multiple hidden>
      <div class="queue" id="queue"></div>
    </section>
    <div class="toolbar">
      <input class="search" id="search" type="search" placeholder="Search files" aria-label="Search files">
      <select class="sort" id="sort" aria-label="Sort files"><option value="name">Name</option><option value="date">Newest</option><option value="size">Largest</option></select>
      <button class="secondary" id="refresh" type="button">Refresh</button>
    </div>
    <div class="table-wrap"><table><thead><tr><th>File</th><th>Size</th><th>Modified</th><th></th></tr></thead><tbody id="files"></tbody></table><div class="empty" id="empty">No files yet.</div></div>
  </main>
  <div class="notice" id="notice" role="status"></div>
  <script>
    var files = [];
    var chunkSize = 8 * 1024 * 1024;
    var fileInput = document.getElementById('fileInput');
    var dropZone = document.getElementById('dropZone');
    var queue = document.getElementById('queue');
    var fileBody = document.getElementById('files');
    var empty = document.getElementById('empty');
    var notice = document.getElementById('notice');

    function formatBytes(value) {
      if (!value) return '0 B';
      var units = ['B','KB','MB','GB','TB'];
      var i = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
      return (value / Math.pow(1024, i)).toFixed(i ? 1 : 0) + ' ' + units[i];
    }
    function showNotice(message, isError) {
      notice.textContent = message; notice.className = 'notice' + (isError ? ' error' : ''); notice.style.display = 'block';
      clearTimeout(showNotice.timer); showNotice.timer = setTimeout(function(){notice.style.display='none'}, 3500);
    }
    async function api(url, options) {
      var response = await fetch(url, options);
      var body = await response.json().catch(function(){return {error:'Request failed'}});
      if (!response.ok) throw new Error(body.error || 'Request failed');
      return body;
    }
    function fileUrl(name) { return '/' + encodeURIComponent(name); }
    function render() {
      var query = document.getElementById('search').value.toLowerCase();
      var sort = document.getElementById('sort').value;
      var shown = files.filter(function(file){return file.name.toLowerCase().includes(query)}).slice();
      shown.sort(function(a,b){if(sort==='date')return b.modified-a.modified;if(sort==='size')return b.size-a.size;return a.name.localeCompare(b.name)});
      fileBody.replaceChildren(); empty.style.display = shown.length ? 'none' : 'block';
      shown.forEach(function(file){
        var row=document.createElement('tr');
        var name=document.createElement('td'); name.className='file-name';
        var link=document.createElement('a'); link.href=fileUrl(file.name); link.textContent=file.name; name.appendChild(link);
        var size=document.createElement('td'); size.textContent=formatBytes(file.size);
        var date=document.createElement('td'); date.textContent=new Date(file.modified).toLocaleString();
        var actions=document.createElement('td'); actions.className='actions';
        var copy=document.createElement('button'); copy.className='icon-action'; copy.textContent='Copy URL'; copy.title='Copy download URL';
        copy.onclick=async function(){await navigator.clipboard.writeText(location.origin+fileUrl(file.name));showNotice('Download URL copied')};
        var remove=document.createElement('button'); remove.className='icon-action delete'; remove.textContent='Delete'; remove.title='Delete file';
        remove.onclick=async function(){if(!confirm('Delete '+file.name+'?'))return;try{await api(fileUrl(file.name),{method:'DELETE'});showNotice('Deleted '+file.name);await refresh()}catch(error){showNotice(error.message,true)}};
        actions.append(copy,remove); row.append(name,size,date,actions); fileBody.appendChild(row);
      });
    }
    async function refresh() {
      try {
        var result=await api('/api/files'); files=result.files; render();
        var status=await api('/api/status'); document.getElementById('storage').textContent=formatBytes(status.used)+' used / '+formatBytes(status.total)+' total';
      } catch(error) { showNotice(error.message,true); }
    }
    function createJob(file) {
      var job=document.createElement('div');job.className='job';
      var name=document.createElement('div');name.className='job-name';name.textContent=file.name;
      var status=document.createElement('div');status.className='job-status';status.textContent='Starting';
      var progress=document.createElement('div');progress.className='progress';var fill=document.createElement('span');progress.appendChild(fill);
      job.append(name,status,progress);queue.appendChild(job);return {job:job,status:status,fill:fill};
    }
    async function upload(file) {
      var ui=createJob(file);
      try {
        var session=await api('/api/uploads',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({filename:file.name,size:file.size})});
        var offset=session.offset;
        while(offset<file.size){
          var end=Math.min(offset+chunkSize,file.size);var chunk=file.slice(offset,end);
          var response=await fetch('/api/uploads/'+session.id,{method:'PATCH',headers:{'Upload-Offset':String(offset),'Content-Type':'application/octet-stream'},body:chunk});
          var result=await response.json().catch(function(){return {error:'Upload failed'}});if(!response.ok)throw new Error(result.error||'Upload failed');
          offset=result.offset;var percent=file.size?Math.round(offset/file.size*100):100;ui.fill.style.width=percent+'%';ui.status.textContent=percent+'%';
        }
        await api('/api/uploads/'+session.id+'/finish',{method:'POST'});ui.status.textContent='Complete';ui.fill.style.width='100%';
        setTimeout(function(){ui.job.remove()},1800);await refresh();
      } catch(error){ui.status.textContent=error.message;ui.status.style.color='var(--red)';showNotice('Upload failed: '+error.message,true)}
    }
    async function uploadAll(list){for(var i=0;i<list.length;i++)await upload(list[i])}
    document.getElementById('chooseButton').onclick=function(){fileInput.click()};
    fileInput.onchange=function(){uploadAll(Array.from(fileInput.files));fileInput.value=''};
    ['dragenter','dragover'].forEach(function(name){dropZone.addEventListener(name,function(event){event.preventDefault();dropZone.classList.add('drag')})});
    ['dragleave','drop'].forEach(function(name){dropZone.addEventListener(name,function(event){event.preventDefault();dropZone.classList.remove('drag')})});
    dropZone.addEventListener('drop',function(event){uploadAll(Array.from(event.dataTransfer.files))});
    document.getElementById('search').oninput=render;document.getElementById('sort').onchange=render;document.getElementById('refresh').onclick=refresh;
    refresh();
  </script>
</body>
</html>`;

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
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
  const userOk = crypto.timingSafeEqual(Buffer.from(sha256(user)), Buffer.from(sha256(AUTH_USER)));
  const passOk = crypto.timingSafeEqual(Buffer.from(passwordHash), Buffer.from(AUTH_PASSWORD_HASH.toLowerCase()));
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

function filenameFromPath(pathname) {
  try {
    const name = decodeURIComponent(pathname.slice(1));
    return validFilename(name) ? name : null;
  } catch { return null; }
}

function fileId(name) {
  return Buffer.from(name, 'utf8').toString('base64url');
}

function filenameFromId(id) {
  if (!/^[A-Za-z0-9_-]+$/.test(id)) return null;
  try {
    const name = Buffer.from(id, 'base64url').toString('utf8');
    return validFilename(name) && fileId(name) === id ? name : null;
  } catch { return null; }
}

function cliFileIdFromPath(pathname) {
  const match = pathname.match(/^\/api\/cli\/files\/([A-Za-z0-9_-]+)$/);
  return match ? match[1] : null;
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
    await handle.sync();
    return total;
  } finally {
    await handle.close();
  }
}

async function listFiles() {
  const entries = await fs.readdir(DATA_DIR, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (!entry.isFile() || entry.name.startsWith('.')) continue;
    const stat = await fs.stat(path.join(DATA_DIR, entry.name));
    files.push({ id: fileId(entry.name), name: entry.name, size: stat.size, modified: stat.mtimeMs });
  }
  return files;
}

async function serveFile(req, res, name) {
  const target = path.join(DATA_DIR, name);
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
    'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
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
  createReadStream(target, { start, end }).pipe(res);
}

async function startUpload(req, res) {
  const body = await readJson(req);
  if (!validFilename(body.filename)) return json(res, 400, { error: 'Invalid filename' }, securityHeaders());
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
  await fs.rename(upload.partPath, path.join(DATA_DIR, upload.metadata.filename));
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
    await fs.rename(temp, path.join(DATA_DIR, name));
    json(res, 201, { ok: true, name, size }, securityHeaders());
  } catch (error) {
    await fs.rm(temp, { force: true });
    throw error;
  }
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
  if (!isAuthorized(req)) return challenge(res);

  if (req.method === 'GET' && url.pathname === '/') {
    res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(HTML) });
    return res.end(HTML);
  }
  if (req.method === 'GET' && url.pathname === '/api/files') return json(res, 200, { files: await listFiles() }, securityHeaders());
  if (req.method === 'GET' && url.pathname === '/api/cli/files') {
    const files = (await listFiles()).sort((a, b) => a.name.localeCompare(b.name));
    if (url.searchParams.get('format') === 'tsv') {
      const body = files.map(file => [file.id, Buffer.from(file.name).toString('base64'), formatBytes(file.size), new Date(file.modified).toISOString()].join('\t')).join('\n') + (files.length ? '\n' : '');
      res.writeHead(200, { ...securityHeaders(), 'Content-Type': 'text/tab-separated-values; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
      return res.end(body);
    }
    return json(res, 200, { files: files.map(file => ({ ...file, sizeLabel: formatBytes(file.size) })) }, securityHeaders());
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

  const cliId = cliFileIdFromPath(url.pathname);
  if (cliId) {
    const cliName = filenameFromId(cliId);
    if (!cliName) return json(res, 400, { error: 'Invalid file ID' }, securityHeaders());
    if (req.method === 'GET' || req.method === 'HEAD') return serveFile(req, res, cliName);
    if (req.method === 'PUT') return directUpload(req, res, cliName);
    if (req.method === 'DELETE') {
      try { await fs.unlink(path.join(DATA_DIR, cliName)); } catch (error) {
        if (error.code === 'ENOENT') return json(res, 404, { error: 'File not found' }, securityHeaders());
        throw error;
      }
      return json(res, 200, { ok: true }, securityHeaders());
    }
    return json(res, 405, { error: 'Method not allowed' }, { ...securityHeaders(), Allow: 'GET, HEAD, PUT, DELETE' });
  }

  const name = filenameFromPath(url.pathname);
  if (!name) return json(res, 404, { error: 'Not found' }, securityHeaders());
  if (req.method === 'GET' || req.method === 'HEAD') return serveFile(req, res, name);
  if (req.method === 'PUT') return directUpload(req, res, name);
  if (req.method === 'DELETE') {
    try { await fs.unlink(path.join(DATA_DIR, name)); } catch (error) {
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
  setInterval(() => cleanupUploads().catch(error => console.error('upload cleanup failed', error)), 60 * 60 * 1000).unref();
  const server = http.createServer((req, res) => {
    handle(req, res).catch(error => {
      console.error(req.method, req.url, error);
      if (!res.headersSent) json(res, error.status || 500, { error: error.status ? error.message : 'Internal server error' }, securityHeaders());
      else res.destroy();
    });
  });
  server.requestTimeout = 30 * 60 * 1000;
  server.headersTimeout = 30 * 1000;
  server.listen(PORT, '0.0.0.0', () => console.log(`TunnelPane listening on ${PORT}`));
}

main().catch(error => { console.error(error); process.exit(1); });
