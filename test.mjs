import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const dataDir = await fs.mkdtemp(path.join(os.tmpdir(), 'tunnelpane-'));
const password = 'test-password';
const hash = crypto.createHash('sha256').update(password).digest('hex');
const port = 31987;
const child = spawn(process.execPath, ['server.js'], {
  cwd: new URL('.', import.meta.url),
  env: { ...process.env, DATA_DIR: dataDir, AUTH_USER: 'test-user', AUTH_PASSWORD_HASH: hash, PUBLIC_URL: `http://127.0.0.1:${port}`, PORT: String(port), MAX_SINGLE_UPLOAD: '1024', MAX_CHUNK_SIZE: '8' },
  stdio: ['ignore', 'pipe', 'inherit'],
});
const base = `http://127.0.0.1:${port}`;
const auth = 'Basic ' + Buffer.from('test-user:' + password).toString('base64');

try {
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('server start timeout')), 5000);
    child.stdout.on('data', data => { if (String(data).includes('listening')) { clearTimeout(timer); resolve(); } });
  });
  assert.equal((await fetch(base + '/')).status, 401);
  assert.equal((await fetch(base + '/healthz')).status, 200);
  const zshClient = await (await fetch(base + '/client.zsh')).text();
  const powershellClient = await (await fetch(base + '/client.ps1')).text();
  assert.match(zshClient, new RegExp(base.replaceAll('.', '\\.')));
  assert.match(powershellClient, new RegExp(base.replaceAll('.', '\\.')));
  assert.doesNotMatch(zshClient, /__TUNNELPANE_URL__/);
  assert.doesNotMatch(powershellClient, /__TUNNELPANE_URL__/);
  assert.match(zshClient, /printf 'Username: '/);
  assert.match(zshClient, /terminal_enter/);
  assert.match(zshClient, /print_key 'TAB'/);
  assert.match(zshClient, /monitor_workers/);
  assert.match(zshClient, /format=tsv2/);
  assert.match(powershellClient, /Read-Host "Password" -AsSecureString/);
  assert.match(powershellClient, /Read-Host "Username"/);
  assert.match(powershellClient, /TreatControlCAsInput/);
  assert.match(powershellClient, /Wait-CancellableTask/);
  assert.match(powershellClient, /Show-TransferProgress/);
  assert.match(powershellClient, /Write-PaneRow/);
  assert.match(powershellClient, /api\/cli\/uploads/);

  let response = await fetch(base + '/hello.txt', { method: 'PUT', headers: { Authorization: auth }, body: 'hello world' });
  assert.equal(response.status, 201);
  response = await fetch(base + '/hello.txt', { headers: { Authorization: auth } });
  assert.equal(await response.text(), 'hello world');
  response = await fetch(base + '/hello.txt', { headers: { Authorization: auth, Range: 'bytes=6-10' } });
  assert.equal(response.status, 206);
  assert.equal(await response.text(), 'world');

  response = await fetch(base + '/api/uploads', { method: 'POST', headers: { Authorization: auth, 'Content-Type': 'application/json' }, body: JSON.stringify({ filename: 'chunked.bin', size: 12 }) });
  const session = await response.json();
  assert.equal(response.status, 201);
  response = await fetch(base + '/api/uploads/' + session.id, { method: 'PATCH', headers: { Authorization: auth, 'Upload-Offset': '0' }, body: '12345678' });
  assert.equal((await response.json()).offset, 8);
  response = await fetch(base + '/api/uploads/' + session.id, { method: 'PATCH', headers: { Authorization: auth, 'Upload-Offset': '8' }, body: '90ab' });
  assert.equal((await response.json()).offset, 12);
  response = await fetch(base + '/api/uploads/' + session.id + '/finish', { method: 'POST', headers: { Authorization: auth } });
  assert.equal(response.status, 200);
  assert.equal(await fs.readFile(path.join(dataDir, 'chunked.bin'), 'utf8'), '1234567890ab');

  response = await fetch(base + '/api/files', { headers: { Authorization: auth } });
  const listing = await response.json();
  assert.deepEqual(listing.files.map(file => file.name).sort(), ['chunked.bin', 'hello.txt']);

  const cliName = 'file with spaces.txt';
  const cliId = Buffer.from(cliName).toString('base64url');
  response = await fetch(base + '/api/cli/files/' + cliId, { method: 'PUT', headers: { Authorization: auth }, body: 'shell client' });
  assert.equal(response.status, 201);
  response = await fetch(base + '/api/cli/files/' + cliId, { headers: { Authorization: auth } });
  assert.equal(await response.text(), 'shell client');
  response = await fetch(base + '/api/cli/files?format=tsv', { headers: { Authorization: auth } });
  const tsv = await response.text();
  assert.match(tsv, new RegExp('^' + cliId + '\\t' + Buffer.from(cliName).toString('base64') + '\\t', 'm'));
  response = await fetch(base + '/api/cli/files?format=tsv2', { headers: { Authorization: auth } });
  const tsv2 = await response.text();
  assert.match(tsv2, new RegExp('^' + cliId + '\\t.*\\t12$', 'm'));
  response = await fetch(base + '/api/cli/files/' + cliId, { method: 'DELETE', headers: { Authorization: auth } });
  assert.equal(response.status, 200);

  const parallelName = 'parallel upload.bin';
  const parallelId = Buffer.from(parallelName).toString('base64url');
  response = await fetch(base + `/api/cli/uploads/${parallelId}?size=20&partSize=8`, { method: 'POST', headers: { Authorization: auth } });
  const parallel = await response.json();
  assert.equal(response.status, 201);
  assert.equal(parallel.partCount, 3);
  for (const [index, body] of [[2, 'qrst'], [0, 'abcdefgh'], [1, 'ijklmnop']]) {
    response = await fetch(base + `/api/cli/uploads/${parallel.id}/parts/${index}`, { method: 'PUT', headers: { Authorization: auth }, body });
    assert.equal(response.status, 201);
  }
  response = await fetch(base + `/api/cli/uploads/${parallel.id}/finish`, { method: 'POST', headers: { Authorization: auth } });
  assert.equal(response.status, 200);
  assert.equal(await fs.readFile(path.join(dataDir, parallelName), 'utf8'), 'abcdefghijklmnopqrst');

  const cancelledName = 'cancelled.bin';
  const cancelledId = Buffer.from(cancelledName).toString('base64url');
  response = await fetch(base + `/api/cli/uploads/${cancelledId}?size=8&partSize=8`, { method: 'POST', headers: { Authorization: auth } });
  const cancelled = await response.json();
  response = await fetch(base + `/api/cli/uploads/${cancelled.id}/parts/0`, { method: 'PUT', headers: { Authorization: auth }, body: '12345678' });
  assert.equal(response.status, 201);
  response = await fetch(base + `/api/cli/uploads/${cancelled.id}`, { method: 'DELETE', headers: { Authorization: auth } });
  assert.equal(response.status, 200);
  response = await fetch(base + `/api/cli/uploads/${cancelled.id}/finish`, { method: 'POST', headers: { Authorization: auth } });
  assert.equal(response.status, 404);

  response = await fetch(base + '/hello.txt', { method: 'DELETE', headers: { Authorization: auth } });
  assert.equal(response.status, 200);
  assert.equal((await fetch(base + '/hello.txt', { headers: { Authorization: auth } })).status, 404);
  console.log('All TunnelPane tests passed');
} finally {
  child.kill('SIGTERM');
  await fs.rm(dataDir, { recursive: true, force: true });
}
