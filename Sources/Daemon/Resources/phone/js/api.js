// The contract with the Mac, in one file: the sealed envelope, paths, the shape of an Agent, how lastReply is shown.
// The two things the brief marks as unsettled (ask.kind for other agents, lastReply's format) change here only.
import { markdown } from './md.js';

const STATUSES = ['working', 'waiting', 'done', 'error', 'idle', 'hibernated', 'exited'];

/** An Agent as the page uses it: an unknown status is idle, an unknown kind of ask is a question (answered by text). */
export function agentFrom(raw) {
  const ask = raw.ask && typeof raw.ask.text === 'string'
    ? { kind: raw.ask.kind === 'permission' ? 'permission' : 'question', text: raw.ask.text }
    : null;
  return { ...raw, status: STATUSES.includes(raw.status) ? raw.status : 'idle', ask };
}

/** `GET agents/<id>` may carry `turns`, the conversation's last ones in order: {role: "user", text, at?} what you
    asked, {role: "did", text} what the agent did, in a line, {role: "agent", text} what it said. The page then shows
    those; without them, `lastReply` alone. */

/** lastReply as DOM nodes. Plain text reads fine through the Markdown parser; swap it here if a format flag arrives. */
export const replyNodes = text => markdown(text ?? '');

/** Set by the page: what to do when the Mac says this device is not paired. */
export const on = { unpaired() {} };

// ---- the envelope
// Everything to the Mac goes as POST /api/call {mac, device, box}. The relay on the way reads which Mac and which
// device, and nothing else: box is AES-256-GCM under a key that came in the pairing link's fragment, which never
// leaves the phone. What is sealed says which way it goes ("q" a request, "r<n>" its answer, "e<n>.<i>" the i-th
// event of a stream), and n never repeats, so nothing can be replayed, swapped or reordered.
// The page itself still comes from the relay: this guards what passes, not against a relay that serves another page.

const text = new TextEncoder(), plain = new TextDecoder();
function encode(bytes) {
  let out = '';
  for (let i = 0; i < bytes.length; i += 8192) out += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(out).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
const decode = value => Uint8Array.from(atob(value.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));

async function seal(key, about, value) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: text.encode(about) }, key, text.encode(JSON.stringify(value)));
  const box = new Uint8Array(12 + sealed.byteLength);
  box.set(iv);
  box.set(new Uint8Array(sealed), 12);
  return encode(box);
}
async function unseal(key, about, box) {
  const bytes = decode(box);
  return JSON.parse(plain.decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.subarray(0, 12), additionalData: text.encode(about) }, key, bytes.subarray(12))));
}

// The pairing: {mac, device, key}. The key is kept as one the page can use and cannot read back.
function store(mode, work) {
  return new Promise((done, failed) => {
    const opening = indexedDB.open('kelp', 1);
    opening.onupgradeneeded = () => opening.result.createObjectStore('kept');
    opening.onerror = () => failed(opening.error);
    opening.onsuccess = () => {
      const asked = work(opening.result.transaction('kept', mode).objectStore('kept'));
      asked.onsuccess = () => done(asked.result);
      asked.onerror = () => failed(asked.error);
    };
  });
}
let me = await store('readonly', kept => kept.get('pairing')).catch(() => null);

let last = 0;
/** A number no earlier request of this phone had: the time, and 12 bits against two in one millisecond. */
// ponytail: past 2^53 in September 2039, when the Mac's Number.isSafeInteger refuses every call; then count from a
// later epoch, with each device's newest number moved over by the Mac.
const stamp = () => last = Math.max(last + 1, Date.now() * 4096 + crypto.getRandomValues(new Uint16Array(1))[0] % 4096);

function send(n, method, path, body, signal) {
  return seal(me.key, 'q', { n, method, path, body }).then(box => fetch('/api/call', {
    method: 'POST', signal,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mac: me.mac, device: me.device, box }),
  }));
}

/** One request. Resolves with the JSON body (or null); rejects with {status, message}, status 0 = the Mac is unreachable. */
export async function api(method, path, body) {
  if (!me) {
    on.unpaired();
    throw { status: 401, message: '' };
  }
  const n = stamp();
  let status, data;
  try {
    const res = await send(n, method, path, body);
    if (res.ok) ({ status, body: data } = await unseal(me.key, 'r' + n, (await res.json()).box));
    else status = res.status;
  } catch {
    throw { status: 0, message: '' };
  }
  if (status === 401) on.unpaired();
  if (status >= 400) throw { status: status >= 500 ? 0 : status, message: data?.error ?? '' };
  return data ?? null;
}

/** Whether this page holds a pairing (the Mac may still have dropped it). */
export const paired = () => !!me;

const id = agent => encodeURIComponent(agent);
/** link: what follows #pair= in the pairing link, "<mac>.<key>". */
export async function pair(link, name) {
  const at = link.indexOf('.'), was = me;   // a link that fails leaves the pairing this phone had
  try {
    me = {
      mac: link.slice(0, at), device: encode(crypto.getRandomValues(new Uint8Array(16))),
      key: await crypto.subtle.importKey('raw', decode(link.slice(at + 1)), 'AES-GCM', false, ['encrypt', 'decrypt']),
    };
  } catch {
    me = was;
    throw { status: 401, message: '' };
  }
  // The link's key is good for this one call: the phone names the key it will keep, which was in no address.
  // (A Mac that doesn't answer "rekeyed" keeps the link's.)
  const mine = crypto.getRandomValues(new Uint8Array(32));
  const answer = await api('POST', 'pair', { name, key: encode(mine) }).catch(error => { me = was; throw error; });
  if (answer?.rekeyed) me.key = await crypto.subtle.importKey('raw', mine, 'AES-GCM', false, ['encrypt', 'decrypt']);
  await store('readwrite', kept => kept.put(me, 'pairing'));
}
export async function unpair() {
  await api('POST', 'unpair');
  me = null;
  await store('readwrite', kept => kept.delete('pairing'));
}
export const list = () => api('GET', 'agents');
export const get = agent => api('GET', `agents/${id(agent)}`);
export const choose = (agent, answer, question) => api('POST', `agents/${id(agent)}/choose`, { answer, question });
export const reply = (agent, text) => api('POST', `agents/${id(agent)}/reply`, { text });
export const read = agent => api('POST', `agents/${id(agent)}/read`);
/** Stops what a working agent does, as Esc in its terminal: it stays, and waits. Only where `GET agents` says `stops: true`. */
export const stop = agent => api('POST', `agents/${id(agent)}/stop`);
/** `GET agents` may also carry `projects` [{id, name, icon}], every project of the Mac, the ones with no agent too,
    and `kinds` [{id, name, default?}], the agents that can be started (`default`: the one Kelp starts by itself); an agent then has `projectId`. */
/** A project's icon as an address for an <img>, or null. Only a PNG or a JPEG is taken. */
export async function icon(project) {
  const { type, data } = await api('GET', `projects/${id(project)}/icon`);
  if (type !== 'image/png' && type !== 'image/jpeg') return null;
  return URL.createObjectURL(new Blob([Uint8Array.from(atob(data), c => c.charCodeAt(0))], { type }));
}
/** Starts an agent of that kind in the project with what it should do; resolves with {id}, the new agent's. */
export const start = (project, agent, prompt) => api('POST', `projects/${id(project)}/agents`, { agent, prompt });
export const pushKey = () => api('GET', 'push/key');
export const subscribe = subscription => api('POST', 'push/subscribe', subscription);
export const unsubscribe = endpoint => api('DELETE', 'push/subscribe', { endpoint });

/** The Mac's events, shaped as an EventSource for the page: onopen, onerror, addEventListener, close. It doesn't
    reconnect by itself: the page does, after asking why it broke. */
export function events() {
  const stop = new AbortController(), heard = {};
  const stream = { onopen: null, onerror: null, addEventListener: (event, listener) => { heard[event] = listener; }, close: () => stop.abort() };
  (async () => {
    if (!me) throw 0;
    const n = stamp(), res = await send(n, 'GET', 'events', undefined, stop.signal);
    if (!res.ok || !res.body) throw 0;
    stream.onopen?.();
    const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
    for (let lines = '', i = 0; ;) {
      const { done, value } = await reader.read();
      if (done) throw 0;
      lines += value;
      for (let at; (at = lines.indexOf('\n')) >= 0; lines = lines.slice(at + 1)) {
        if (!at) continue;   // an empty line keeps the connection alive
        const { event, data } = await unseal(me.key, `e${n}.${i++}`, JSON.parse(lines.slice(0, at)).box);
        heard[event]?.({ data: JSON.stringify(data) });
      }
    }
  })().catch(() => { if (!stop.signal.aborted) stream.onerror?.(); });
  return stream;
}
