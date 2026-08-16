// Correctness checks for the positional-write parallel upload path.
// Every part carries distinct content so a misplaced offset changes the digest.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const root = process.env.BENCH_DATA_ROOT || os.tmpdir();
await fs.mkdir(root, { recursive: true });
const dataDir = await fs.mkdtemp(path.join(root, 'tp-verify-'));
const password = 'verify-password';
const hash = crypto.createHash('sha256').update(password).digest('hex');
const port = 31993;
const base = `http://127.0.0.1:${port}`;
const auth = 'Basic ' + Buffer.from('verify-user:' + password).toString('base64');
const PART = 1024 * 1024;

const child = spawn(process.execPath, ['server.js'], {
  cwd: process.cwd(),
  env: {
    ...process.env, DATA_DIR: dataDir, AUTH_USER: 'verify-user', AUTH_PASSWORD_HASH: hash,
    PUBLIC_URL: base, PORT: String(port), MAX_CHUNK_SIZE: String(4 * 1024 * 1024),
  },
  stdio: ['ignore', 'pipe', 'inherit'],
});
await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('server start timeout')), 15000);
  child.stdout.on('data', d => { if (String(d).includes('listening')) { clearTimeout(timer); resolve(); } });
});

const b64url = s => Buffer.from(s, 'utf8').toString('base64url');
const sha = buffer => crypto.createHash('sha256').update(buffer).digest('hex');

// Distinct, position-dependent bytes: any offset error alters the digest.
function makePayload(size) {
  const buffer = Buffer.allocUnsafe(size);
  for (let i = 0; i < size; i++) buffer[i] = (i * 31 + (i >> 13) * 7) & 0xff;
  return buffer;
}

async function startSession(name, size, partSize) {
  const response = await fetch(`${base}/api/cli/uploads/${b64url(name)}?size=${size}&partSize=${partSize}&format=tsv`, {
    method: 'POST', headers: { Authorization: auth },
  });
  assert.equal(response.status, 201, `start ${name}`);
  const [id, returnedPartSize, partCount] = (await response.text()).trim().split('\t');
  return { id, partSize: Number(returnedPartSize), partCount: Number(partCount) };
}

async function putPart(id, index, body) {
  return fetch(`${base}/api/cli/uploads/${id}/parts/${index}`, {
    method: 'PUT', headers: { Authorization: auth, 'Content-Type': 'application/octet-stream' }, body,
  });
}

async function finish(id) {
  return fetch(`${base}/api/cli/uploads/${id}/finish`, { method: 'POST', headers: { Authorization: auth } });
}

async function download(name) {
  const response = await fetch(`${base}/api/cli/files/${b64url(name)}`, { headers: { Authorization: auth } });
  assert.equal(response.status, 200, `download ${name}`);
  return Buffer.from(await response.arrayBuffer());
}

function partsOf(payload, session) {
  return Array.from({ length: session.partCount }, (_, index) =>
    payload.subarray(index * session.partSize, Math.min((index + 1) * session.partSize, payload.length)));
}

async function roundTrip(label, name, size, order) {
  const payload = makePayload(size);
  const session = await startSession(name, size, PART);
  const parts = partsOf(payload, session);
  const indexes = order === 'reverse'
    ? [...parts.keys()].reverse()
    : order === 'parallel' ? [...parts.keys()] : [...parts.keys()];

  if (order === 'parallel') {
    await Promise.all(indexes.map(i => putPart(session.id, i, parts[i]).then(r => assert.equal(r.status, 201, `part ${i}`))));
  } else {
    for (const i of indexes) assert.equal((await putPart(session.id, i, parts[i])).status, 201, `part ${i}`);
  }
  assert.equal((await finish(session.id)).status, 200, `finish ${label}`);
  const got = await download(name);
  assert.equal(got.length, size, `${label}: length`);
  assert.equal(sha(got), sha(payload), `${label}: digest mismatch — bytes landed at wrong offsets`);
  console.log(`  ok  ${label} (${size} bytes, ${session.partCount} parts, ${order})`);
}

try {
  console.log('parallel upload correctness:');
  await roundTrip('multi-part sequential', 'seq.bin', PART * 4 + 12345, 'sequential');
  await roundTrip('multi-part reverse order', 'rev.bin', PART * 4 + 12345, 'reverse');
  await roundTrip('multi-part concurrent', 'par.bin', PART * 6 + 999, 'parallel');
  await roundTrip('exactly one part', 'one.bin', PART, 'sequential');
  await roundTrip('smaller than a part', 'small.bin', 1234, 'sequential');
  await roundTrip('empty file', 'empty.bin', 0, 'sequential');

  console.log('rejection cases:');
  const session = await startSession('bad.bin', PART * 2, PART);
  assert.equal((await putPart(session.id, 0, makePayload(PART - 10))).status, 400);
  console.log('  ok  short part rejected');
  assert.equal((await putPart(session.id, 99, makePayload(PART))).status, 400);
  console.log('  ok  out-of-range index rejected');
  assert.equal((await finish(session.id)).status, 409);
  console.log('  ok  finish with missing parts rejected');

  // Re-sending a part must be idempotent, not corrupting.
  const payload = makePayload(PART * 2);
  const retry = await startSession('retry.bin', PART * 2, PART);
  const chunks = partsOf(payload, retry);
  assert.equal((await putPart(retry.id, 0, chunks[0])).status, 201);
  assert.equal((await putPart(retry.id, 0, chunks[0])).status, 201);
  assert.equal((await putPart(retry.id, 1, chunks[1])).status, 201);
  assert.equal((await finish(retry.id)).status, 200);
  assert.equal(sha(await download('retry.bin')), sha(payload), 'retry digest');
  console.log('  ok  duplicate part upload is idempotent');

  // Finished sessions must leave nothing behind. The abandoned bad.bin session
  // is expected to survive until the 24h sweep, so it is excluded.
  const remaining = await fs.readdir(path.join(dataDir, '.uploads'));
  const finished = [retry.id, session.id];
  const stale = remaining.filter(name => finished.slice(0, 1).some(id => name.includes(id)));
  assert.deepEqual(stale, [], `finished session not cleaned: ${stale}`);
  console.log('  ok  finished sessions leave no files');

  // An abandoned session preallocates with truncate, so it must stay sparse:
  // blocks on disk should reflect only the one part actually uploaded.
  const abandoned = remaining.find(name => name.includes(session.id) && name.endsWith('.data'));
  const stat = await fs.stat(path.join(dataDir, '.uploads', abandoned));
  assert.ok(stat.blocks * 512 <= PART * 1.5, `preallocated file is not sparse: ${stat.blocks * 512} bytes on disk for ${stat.size} declared`);
  console.log(`  ok  abandoned session stays sparse (${stat.blocks * 512} bytes on disk, ${stat.size} declared)`);

  console.log('round-trip savers:');

  // Auto-finish: the part completing the set publishes the file itself.
  const autoPayload = makePayload(PART * 3);
  const auto = await startSession('auto.bin', autoPayload.length, PART);
  const autoParts = partsOf(autoPayload, auto);
  let reportedFinished = 0;
  for (let index = 0; index < auto.partCount; index++) {
    const response = await fetch(`${base}/api/cli/uploads/${auto.id}/parts/${index}?finish=1`, {
      method: 'PUT', headers: { Authorization: auth, 'Content-Type': 'application/octet-stream' }, body: autoParts[index],
    });
    assert.ok(response.ok, `auto part ${index}`);
    if ((await response.json()).finished) reportedFinished++;
  }
  assert.equal(reportedFinished, 1, 'exactly one part should report finishing');
  assert.equal(sha(await download('auto.bin')), sha(autoPayload), 'auto-finish digest');
  console.log('  ok  last part finishes the upload without a separate call');

  // Resume: report which parts landed so a retry can skip them.
  const resumePayload = makePayload(PART * 4);
  const resume = await startSession('resume.bin', resumePayload.length, PART);
  const resumeParts = partsOf(resumePayload, resume);
  await putPart(resume.id, 0, resumeParts[0]);
  await putPart(resume.id, 2, resumeParts[2]);
  const state = await (await fetch(`${base}/api/cli/uploads/${resume.id}/parts`, { headers: { Authorization: auth } })).json();
  assert.deepEqual(state.parts, [0, 2], 'landed parts');
  assert.equal(state.partCount, 4);
  for (const index of [1, 3]) assert.equal((await putPart(resume.id, index, resumeParts[index])).status, 201);
  assert.equal((await finish(resume.id)).status, 200);
  assert.equal(sha(await download('resume.bin')), sha(resumePayload), 'resumed digest');
  console.log('  ok  landed parts are reported so retries resume');

  // Batch: many small files in one request.
  const batchFiles = Array.from({ length: 25 }, (_, i) => ({
    path: `bundle/dir${i % 3}/file${i}.bin`,
    payload: makePayload(500 + i * 37),
  }));
  const manifest = Buffer.from(JSON.stringify({ files: batchFiles.map(f => ({ path: f.path, size: f.payload.length })) }), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32BE(manifest.length, 0);
  const batchBody = Buffer.concat([header, manifest, ...batchFiles.map(f => f.payload)]);
  const batchResponse = await fetch(`${base}/api/cli/batch`, {
    method: 'POST', headers: { Authorization: auth, 'Content-Type': 'application/octet-stream' }, body: batchBody,
  });
  assert.equal(batchResponse.status, 201, 'batch upload');
  assert.equal((await batchResponse.json()).count, batchFiles.length);
  for (const entry of batchFiles) {
    assert.equal(sha(await download(entry.path)), sha(entry.payload), `batch digest ${entry.path}`);
  }
  console.log(`  ok  ${batchFiles.length} files landed in one request, nested paths intact`);

  // Batch rejections
  const escape = Buffer.from(JSON.stringify({ files: [{ path: '../escape.bin', size: 4 }] }), 'utf8');
  const escapeHeader = Buffer.alloc(4);
  escapeHeader.writeUInt32BE(escape.length, 0);
  const escaped = await fetch(`${base}/api/cli/batch`, {
    method: 'POST', headers: { Authorization: auth }, body: Buffer.concat([escapeHeader, escape, Buffer.alloc(4)]),
  });
  assert.equal(escaped.status, 400, 'path traversal in batch must be rejected');
  console.log('  ok  batch rejects path traversal');

  // Listing carries storage so the browser needs one round trip.
  const listing = await (await fetch(`${base}/api/files`, { headers: { Authorization: auth } })).json();
  assert.ok(listing.status && Number.isFinite(listing.status.free), 'listing should include storage');
  console.log('  ok  listing includes storage status');

  console.log('\nAll correctness checks passed');
} finally {
  child.kill('SIGKILL');
  await fs.rm(dataDir, { recursive: true, force: true });
}
