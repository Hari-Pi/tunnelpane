// Benchmark harness: measures parallel upload + range download throughput
// against a locally spawned server.js. Run inside the node:22-alpine image.
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const SIZE = Number(process.env.BENCH_SIZE || 128 * 1024 * 1024);
const PART = Number(process.env.BENCH_PART || 16 * 1024 * 1024);
const WORKERS = Number(process.env.BENCH_WORKERS || 4);
const ROUNDS = Number(process.env.BENCH_ROUNDS || 3);

const root = process.env.BENCH_DATA_ROOT || os.tmpdir();
await fs.mkdir(root, { recursive: true });
const dataDir = await fs.mkdtemp(path.join(root, 'tp-bench-'));
const password = 'bench-password';
const hash = crypto.createHash('sha256').update(password).digest('hex');
const port = 31991;
const base = `http://127.0.0.1:${port}`;
const auth = 'Basic ' + Buffer.from('bench-user:' + password).toString('base64');

const child = spawn(process.execPath, ['server.js'], {
  cwd: process.cwd(),
  env: {
    ...process.env,
    DATA_DIR: dataDir,
    AUTH_USER: 'bench-user',
    AUTH_PASSWORD_HASH: hash,
    PUBLIC_URL: base,
    PORT: String(port),
    MAX_SINGLE_UPLOAD: String(128 * 1024 * 1024),
    MAX_CHUNK_SIZE: String(32 * 1024 * 1024),
  },
  stdio: ['ignore', 'pipe', 'inherit'],
});

await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('server start timeout')), 15000);
  child.stdout.on('data', d => { if (String(d).includes('listening')) { clearTimeout(timer); resolve(); } });
});

const payload = crypto.randomBytes(PART); // reused per part; content does not affect I/O cost
const b64url = s => Buffer.from(s, 'utf8').toString('base64url');
const rate = (bytes, ms) => (bytes / 1048576 / (ms / 1000)).toFixed(1);

async function pooled(count, workers, task) {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(workers, count) }, async () => {
    while (true) {
      const index = next++;
      if (index >= count) return;
      await task(index);
    }
  }));
}

async function uploadOnce(name) {
  const start = process.hrtime.bigint();
  const session = await fetch(`${base}/api/cli/uploads/${b64url(name)}?size=${SIZE}&partSize=${PART}&format=tsv`, {
    method: 'POST', headers: { Authorization: auth },
  });
  if (!session.ok) throw new Error('start failed: ' + session.status + ' ' + await session.text());
  const [id, partSize, partCount] = (await session.text()).trim().split('\t');
  const parts = Number(partCount);

  await pooled(parts, WORKERS, async index => {
    const expected = index === parts - 1 ? SIZE - index * Number(partSize) : Number(partSize);
    const response = await fetch(`${base}/api/cli/uploads/${id}/parts/${index}`, {
      method: 'PUT',
      headers: { Authorization: auth, 'Content-Type': 'application/octet-stream' },
      body: payload.subarray(0, expected),
    });
    if (!response.ok) throw new Error('part ' + index + ' failed: ' + response.status + ' ' + await response.text());
  });

  const finish = await fetch(`${base}/api/cli/uploads/${id}/finish`, { method: 'POST', headers: { Authorization: auth } });
  if (!finish.ok) throw new Error('finish failed: ' + finish.status + ' ' + await finish.text());
  return Number(process.hrtime.bigint() - start) / 1e6;
}

async function downloadOnce(name) {
  const start = process.hrtime.bigint();
  const parts = Math.ceil(SIZE / PART);
  let received = 0;
  await pooled(parts, WORKERS, async index => {
    const from = index * PART;
    const to = Math.min(from + PART, SIZE) - 1;
    const response = await fetch(`${base}/api/cli/files/${b64url(name)}`, {
      headers: { Authorization: auth, Range: `bytes=${from}-${to}` },
    });
    if (response.status !== 206) throw new Error('range failed: ' + response.status);
    const bytes = (await response.arrayBuffer()).byteLength;
    received = received + bytes;
  });
  if (received !== SIZE) throw new Error(`download size mismatch: ${received} != ${SIZE}`);
  return Number(process.hrtime.bigint() - start) / 1e6;
}

async function listOnce() {
  const start = process.hrtime.bigint();
  const response = await fetch(`${base}/api/cli/files?format=tsv3`, { headers: { Authorization: auth } });
  if (!response.ok) throw new Error('list failed: ' + response.status);
  await response.text();
  return Number(process.hrtime.bigint() - start) / 1e6;
}

const median = values => values.slice().sort((a, b) => a - b)[Math.floor(values.length / 2)];

try {
  const uploads = [];
  const downloads = [];
  for (let round = 0; round < ROUNDS; round++) {
    uploads.push(await uploadOnce(`bench-${round}.bin`));
    downloads.push(await downloadOnce(`bench-${round}.bin`));
  }

  // Directory listing cost with many entries
  await fs.mkdir(path.join(dataDir, 'many'), { recursive: true });
  await Promise.all(Array.from({ length: 300 }, (_, i) => fs.writeFile(path.join(dataDir, 'many', `f${i}.txt`), 'x')));
  const lists = [];
  for (let i = 0; i < 5; i++) lists.push(await listOnce());

  const mb = (SIZE / 1048576).toFixed(0);
  console.log(JSON.stringify({
    sizeMB: Number(mb),
    partMB: PART / 1048576,
    workers: WORKERS,
    uploadMs: uploads.map(v => Math.round(v)),
    uploadMedianMs: Math.round(median(uploads)),
    uploadMBps: Number(rate(SIZE, median(uploads))),
    downloadMs: downloads.map(v => Math.round(v)),
    downloadMedianMs: Math.round(median(downloads)),
    downloadMBps: Number(rate(SIZE, median(downloads))),
    listMedianMs: Math.round(median(lists)),
  }, null, 2));
} finally {
  child.kill('SIGKILL');
  await fs.rm(dataDir, { recursive: true, force: true });
}
