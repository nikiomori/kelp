// Kelp's phone relay: one address for every Mac. It serves ../phone to the phone and passes the phone's calls to the
// right Mac, which holds a connection open to here, so no Mac needs an address of its own. No dependencies.
//
//   phone → POST /api/call {mac, device, box}   box is sealed between the phone and the Mac (phone/js/api.js):
//                                               the relay reads which Mac and which device, and nothing else
//   Mac   → GET  /mac/<id>/requests             a stream of lines, one phone call a line
//   Mac   → POST /mac/<id>/responses            its sealed answer, or a line of an event stream
//
// Push does not pass here: a Mac sends its own to the phone's push service.
import { createServer } from 'node:http';
import { BlockList, isIPv6 } from 'node:net';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const PORT = +process.env.PORT || 8080;
// The phone's page as Kelp ships it; PHONE names another folder (one checked out beside a released Kelp).
const ROOT = process.env.PHONE ? normalize(process.env.PHONE + '/') : fileURLToPath(new URL('../Sources/Daemon/Resources/phone/', import.meta.url));
const DATA = process.env.DATA || fileURLToPath(new URL('./data/', import.meta.url));
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml',
};
const LIMITS = { macs: 100000, macsFromOne: 20, newFromOne: 20, waiting: 32, phoneBody: 1 << 17, macBody: 1 << 21, answerIn: 20000, forgetAfter: 180 * 86400000 };

// A Mac is known by the hash of the secret it first came with: nobody else can come as it later.
// One not seen for half a year is forgotten, and one address may hold only so many connections and register only so
// many a day (isMac): the list can't be filled by one caller.
const known = new Map(Object.entries(JSON.parse(await readFile(join(DATA, 'macs.json'), 'utf8').catch(() => '{}'))));   // id → {hash, seen}
const live = new Map();   // id → { stream, from, waiting: call → {res, timer}, streams: call → res }
const sha = text => createHash('sha256').update(text).digest();
// Who calls: the address the proxy in front saw (X-Real-IP, which it sets over whatever the caller sent), and only when
// that is Cloudflare, the one Cloudflare names. The origin answers without Cloudflare too, so the caller's own header
// can't be taken on its word. Ranges from cloudflare.com/ips.
const CLOUDFLARE = new BlockList();
for (const range of [
  '173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '141.101.64.0/18', '108.162.192.0/18',
  '190.93.240.0/20', '188.114.96.0/20', '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13',
  '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22',
  '2400:cb00::/32', '2606:4700::/32', '2803:f800::/32', '2405:b500::/32', '2405:8100::/32', '2a06:98c0::/29', '2c0f:f248::/32',
]) {
  const [ip, bits] = range.split('/');
  CLOUDFLARE.addSubnet(ip, +bits, isIPv6(ip) ? 'ipv6' : 'ipv4');
}
function from(req) {
  const peer = req.headers['x-real-ip'] ?? req.socket.remoteAddress ?? '';
  const named = req.headers['cf-connecting-ip'];
  return named && CLOUDFLARE.check(peer, isIPv6(peer) ? 'ipv6' : 'ipv4') ? named : peer;
}
// An IPv6 caller holds a whole /64: it counts as one address.
// ponytail: the first four groups as written, so a '::' among them miscounts; a caller with a /48 still gets 65 536.
const block = address => (address?.includes(':') && !address.startsWith('::ffff:') ? address.split(':').slice(0, 4).join(':') : address);
const fresh = new Map();   // address → Macs it registered today
let saving;
const save = () => saving ??= setTimeout(async () => {
  saving = null;
  await mkdir(DATA, { recursive: true });
  await writeFile(join(DATA, 'macs.json'), JSON.stringify(Object.fromEntries(known)));
}, 5000);
function forget() {
  fresh.clear();
  for (const [id, mac] of known) if (Date.now() - mac.seen > LIMITS.forgetAfter && !live.has(id)) known.delete(id);
  save();
}
forget();
setInterval(forget, 86400000);

/** 0 when it is this Mac, else the status to refuse it with. */
function isMac(req, id) {
  const secret = /^Bearer ([\w-]{32,128})$/.exec(req.headers.authorization ?? '')?.[1];
  if (!secret || !/^[\w-]{16,64}$/.test(id)) return 401;
  const mac = known.get(id);
  if (mac) {
    if (!timingSafeEqual(sha(secret), Buffer.from(mac.hash, 'hex'))) return 401;
    if (Date.now() - mac.seen > 86400000) { mac.seen = Date.now(); save(); }
    return 0;
  }
  const caller = block(from(req)), today = fresh.get(caller) ?? 0;
  if (known.size >= LIMITS.macs || today >= LIMITS.newFromOne) return 429;
  fresh.set(caller, today + 1);
  known.set(id, { hash: sha(secret).toString('hex'), seen: Date.now() });
  save();
  return 0;
}

function json(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...headers });
  res.end(body === undefined ? '' : JSON.stringify(body));
}
const fail = (res, status, error) => json(res, status, { error });
async function read(req, limit) {
  let text = '';
  for await (const chunk of req) {
    text += chunk;
    if (text.length > limit) throw Object.assign(new Error('too large'), { status: 413 });
  }
  return text;
}

// ---- the Mac's side

function requests(req, res, id) {
  const caller = from(req);
  let same = 0;
  for (const [other, mac] of live) if (block(mac.from) === block(caller) && other !== id) same++;
  if (same >= LIMITS.macsFromOne) return fail(res, 429, 'Too many Macs from one address.');
  live.get(id)?.stream.end();   // the Mac came again: its old connection is dead
  const mac = { stream: res, from: caller, waiting: new Map(), streams: new Map() };
  live.set(id, mac);
  res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' });
  res.write('\n');
  const beat = setInterval(() => res.write('\n'), 25000);   // a proxy on the way cuts a silent connection
  res.on('close', () => {
    clearInterval(beat);
    for (const { res: phone, timer } of mac.waiting.values()) { clearTimeout(timer); fail(phone, 503, 'This Mac is not connected.'); }
    for (const phone of mac.streams.values()) phone.end();
    if (live.get(id) === mac) live.delete(id);
  });
}

function answer(mac, msg) {
  const wait = mac.waiting.get(msg.id);
  if (wait) {
    clearTimeout(wait.timer);
    mac.waiting.delete(msg.id);
    if (msg.stream) {
      mac.streams.set(msg.id, wait.res);
      wait.res.writeHead(200, { 'Content-Type': 'application/x-ndjson', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' });
      return wait.res.write('\n');
    }
    if (msg.status === 200 && typeof msg.box === 'string') return json(wait.res, 200, { box: msg.box });
    return fail(wait.res, Number.isInteger(msg.status) && msg.status >= 400 && msg.status < 600 ? msg.status : 502, 'Refused.');
  }
  const stream = mac.streams.get(msg.id);
  if (!stream) return;
  if (typeof msg.line === 'string') stream.write(msg.line);
  if (msg.end) { stream.end(); mac.streams.delete(msg.id); }
}

// ---- the phone's side

async function phone(req, res) {
  const sent = JSON.parse(await read(req, LIMITS.phoneBody));
  if (typeof sent?.device !== 'string' || typeof sent.box !== 'string') return fail(res, 400, 'Send {mac, device, box}.');
  const mac = live.get(sent.mac);
  if (!mac) return fail(res, 503, 'This Mac is not connected.');
  if (mac.waiting.size >= LIMITS.waiting) return fail(res, 429, 'Too many requests at once.');
  const call = randomBytes(8).toString('hex');
  const timer = setTimeout(() => { mac.waiting.delete(call); fail(res, 504, 'The Mac did not answer.'); }, LIMITS.answerIn);
  mac.waiting.set(call, { res, timer });
  res.on('close', () => {   // the phone left: an event stream on the Mac must not stay open for it
    if (!mac.waiting.delete(call) && !mac.streams.delete(call)) return;
    clearTimeout(timer);
    mac.stream.write(JSON.stringify({ id: call, cancel: true }) + '\n');
  });
  mac.stream.write(JSON.stringify({ id: call, device: sent.device, box: sent.box }) + '\n');
}

createServer(async (req, res) => {
  const { pathname } = new URL(req.url, 'http://localhost');
  try {
    const mac = /^\/mac\/([^/]+)\/(requests|responses)$/.exec(pathname);
    if (mac) {
      const refused = isMac(req, mac[1]);
      if (refused) return fail(res, refused, refused === 429 ? 'Too many new Macs from one address.' : 'Not this Mac.');
      if (mac[2] === 'requests' && req.method === 'GET') return requests(req, res, mac[1]);
      if (mac[2] === 'responses' && req.method === 'POST') {
        const to = live.get(mac[1]);
        if (to) answer(to, JSON.parse(await read(req, LIMITS.macBody)));
        return json(res, 204);
      }
      return fail(res, 405, 'Not allowed.');
    }
    if (pathname === '/api/call' && req.method === 'POST') return await phone(req, res);
    if (pathname.startsWith('/api/')) return fail(res, 404, 'No such path.');
    const file = normalize(join(ROOT, pathname === '/' ? 'index.html' : pathname));
    if (!file.startsWith(ROOT) || !TYPES[extname(file)]) return fail(res, 404, 'Not found.');
    const bytes = await readFile(file);
    res.writeHead(200, {
      'Content-Type': TYPES[extname(file)], 'Cache-Control': 'no-store',
      // blob: a project's icon, which the page opens from a sealed call.
      'Content-Security-Policy': "default-src 'self'; img-src 'self' blob:", 'X-Content-Type-Options': 'nosniff',
    });
    res.end(bytes);
  } catch (error) {
    if (res.headersSent) return res.end();
    if (error.code === 'ENOENT') return fail(res, 404, 'Not found.');
    if (error.status === 413) return fail(res, 413, 'Too large.');
    if (error instanceof SyntaxError) return fail(res, 400, 'The body is not JSON.');
    console.error(error);
    fail(res, 500, 'The relay broke.');
  }
}).listen(PORT, () => console.log(`Kelp phone relay on :${PORT}, ${known.size} Macs known`));
