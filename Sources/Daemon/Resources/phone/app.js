import * as kelp from './js/api.js';
import { follow, tuneLens } from './js/glass.js';

// An iPhone keeps a Home Screen app's data apart from Safari's: pairing in Safari pairs Safari alone.
// An iPad's Safari names itself a Mac: it has a touch screen, which a Mac hasn't.
const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
// A tablet or a computer's browser: the list stays beside the agent, as Mail lays them out (app.css, the same width).
const wide = matchMedia('(min-width: 768px)');
// A keyboard with a pointer: Return sends, Shift-Return starts a new line.
const keyboard = matchMedia('(pointer: fine)');
const standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone === true;

// The pairing link's code. It leaves the address when it is used (`forget`), and is kept nowhere.
const codeIn = text => text.match(/#pair=([^\s#]+)$/)?.[1];
const forget = () => history.replaceState(null, '', location.pathname);
/** An address's part as it was typed: a stray % in it stays as it is. */
const decoded = text => { try { return decodeURIComponent(text); } catch { return text; } };

// Every string the page shows, in one place for translation: English, and Russian where the phone speaks it.
const EN = {
  connecting: 'Connecting to your Mac…',
  scanAgain: standalone
    ? "On your Mac open Kelp › Settings › Phone and scan the code with this phone's camera. On the page that opens tap Copy Pairing Link, then come back and paste it here."
    : 'Open Kelp on your Mac, go to Settings › Phone and scan the code again.',
  install: 'Keep Kelp on the Home Screen: only from there can it tell you when an agent needs you.',
  steps: ['Tap Copy Pairing Link.', 'Tap Share, then Add to Home Screen.', 'Open Kelp from the Home Screen and tap Paste Pairing Link if it asks.'],
  copy: 'Copy Pairing Link', copied: 'Copied. Now add Kelp to the Home Screen.', here: 'Use It in Safari Instead',
  paste: 'Paste Pairing Link', link: 'Pairing link', connect: 'Connect', badLink: "That isn't a pairing link.",
  cantReach: mac => `Can't reach ${mac || 'your Mac'}. Trying again…`,
  failed: mac => `Can't reach ${mac || 'your Mac'}.`,
  empty: mac => `No agents are running on ${mac || 'your Mac'}.`,
  status: {
    waiting: 'Needs you', working: 'Working', done: 'Done', error: 'Error',
    idle: 'Idle', hibernated: 'Paused', exited: 'Exited',
  },
  now: 'now',
  unread: 'unread',
  allow: 'Allow',
  deny: 'Deny',
  changed: 'The question changed. Check it and answer again.',
  asks: 'Asks:',
  // What a permission is for, from Kelp's question ("Allow rm -rf node_modules?", "Allow editing App.swift?").
  asksTo: {
    run: 'Asks to run', edit: 'Asks to edit', write: 'Asks to write', read: 'Asks to read', fetch: 'Asks to open',
    search: 'Asks to search the web for', use: 'Asks to use',
  },
  answer: 'Answer',
  answerTo: name => `Your answer goes to ${name || 'the agent'}`,
  quiet: { hibernated: 'paused', exited: 'ended', idle: 'idle', done: 'done' },
  more: (n, kinds) => `${n} more: ${kinds}`,
  fewer: 'Show Fewer',
  stop: 'Stop',
  whileWorking: 'Message, read when it stops',
  connected: 'Connected, sealed end to end',
  outOfReach: "Can't reach it. Trying again…",
  failedLead: 'Failed:',
  limitLead: 'Limit:',
  limitShort: (kind, resets) => kind + (resets ? `, resets ${resets}` : ''),
  limitWord: kind => `Hit its ${kind} limit`,
  counts: { waiting: n => (n === 1 ? 'needs you' : 'need you'), working: () => 'working', done: () => 'done' },
  other: 'Other',
  newIn: project => `New agent in ${project}`, agentKind: 'Agent', whatToDo: 'What should it do?', startIt: 'Start',
  notStarted: "The Mac didn't start it.",
  limit: (kind, resets) => `Hit its ${kind} limit.` + (resets ? ` Resets ${resets}.` : ''),
  continues: time => ` Continues at ${time}.`,
  ended: 'This agent has ended.',
  message: 'Message',
  send: 'Send',
  quickContinue: ['Continue', 'continue'],
  quickGood: ['Looks Good, Go On', 'Looks good, go on'],
  back: 'Agents',
  menu: 'Menu',
  thisPhone: 'This Phone',
  close: 'Close',
  done: 'Done',
  notifications: 'Notifications',
  pushWhen: 'When an agent asks or fails',
  pushBlocked: 'Blocked. Allow notifications for Kelp in the Settings app, then come back.',
  pushUnavailable: 'Not available in this browser.',
  pushFailed: "Couldn't change notifications. Try again.",
  addToHome: 'For notifications Kelp has to be on the Home Screen, paired there: scan the code in Kelp › Settings › Phone again and follow the steps.',
  disconnect: 'Disconnect This Phone…',
  disconnectAsk: mac => `Disconnect this phone from ${mac || 'your Mac'}? To connect again, scan a new code in Kelp.`,
  disconnectYes: 'Disconnect',
  cancel: 'Cancel',
  pick: 'Choose an agent on the left',
  units: { m: 'm', h: 'h', d: 'd' },
};
const one = n => n % 10 === 1 && n % 100 !== 11;
const RU = {
  connecting: 'Подключение к вашему Mac…',
  scanAgain: standalone
    ? 'На Mac откройте Kelp › Настройки › Телефон и наведите на код камеру этого телефона. На открывшейся странице нажмите «Скопировать ссылку для подключения», вернитесь сюда и вставьте её.'
    : 'Откройте Kelp на Mac, зайдите в Настройки › Телефон и отсканируйте код ещё раз.',
  install: 'Держите Kelp на экране «Домой»: только оттуда он сможет сообщить, что агенту нужны вы.',
  steps: ['Нажмите «Скопировать ссылку для подключения».', 'Нажмите «Поделиться», затем «На экран „Домой“».', 'Откройте Kelp с экрана «Домой» и, если он попросит, нажмите «Вставить ссылку для подключения».'],
  copy: 'Скопировать ссылку для подключения', copied: 'Скопировано. Теперь добавьте Kelp на экран «Домой».', here: 'Остаться в Safari',
  paste: 'Вставить ссылку для подключения', link: 'Ссылка для подключения', connect: 'Подключить', badLink: 'Это не ссылка для подключения.',
  cantReach: mac => `Нет связи с ${mac || 'вашим Mac'}. Пробую ещё раз…`,
  failed: mac => `Нет связи с ${mac || 'вашим Mac'}.`,
  empty: mac => `На ${mac || 'вашем Mac'} не работает ни один агент.`,
  status: {
    waiting: 'Ждёт вас', working: 'Работает', done: 'Готово', error: 'Ошибка',
    idle: 'Свободен', hibernated: 'На паузе', exited: 'Завершён',
  },
  now: 'сейчас',
  unread: 'не прочитано',
  allow: 'Разрешить',
  deny: 'Запретить',
  changed: 'Вопрос изменился. Посмотрите его и ответьте ещё раз.',
  asks: 'Спрашивает:',
  asksTo: {
    run: 'Хочет выполнить', edit: 'Хочет изменить', write: 'Хочет записать', read: 'Хочет прочитать', fetch: 'Хочет открыть',
    search: 'Хочет найти в интернете', use: 'Хочет использовать',
  },
  answer: 'Ответить',
  answerTo: name => `Ваш ответ получит ${name || 'агент'}`,
  quiet: { hibernated: 'на паузе', exited: 'завершён', idle: 'свободен', done: 'готово' },
  more: (n, kinds) => `Ещё ${n}: ${kinds}`,
  fewer: 'Свернуть',
  stop: 'Остановить',
  whileWorking: 'Сообщение, прочитает, когда остановится',
  connected: 'Подключено, зашифровано от начала до конца',
  outOfReach: 'Нет связи. Пробую ещё раз…',
  failedLead: 'Ошибка:',
  limitLead: 'Лимит:',
  limitShort: (kind, resets) => kind + (resets ? `, сбросится ${resets}` : ''),
  limitWord: kind => `Упёрся в лимит: ${kind}`,
  counts: {
    waiting: n => (one(n) ? 'ждёт вас' : 'ждут вас'), working: n => (one(n) ? 'работает' : 'работают'),
    done: () => 'готово',
  },
  other: 'Другие',
  newIn: project => `Новый агент в ${project}`, agentKind: 'Агент', whatToDo: 'Что ему сделать?', startIt: 'Запустить',
  notStarted: 'Mac не запустил агента.',
  limit: (kind, resets) => `Упёрся в лимит: ${kind}.` + (resets ? ` Сбросится ${resets}.` : ''),
  continues: time => ` Продолжит в ${time}.`,
  ended: 'Этот агент завершён.',
  message: 'Сообщение',
  send: 'Отправить',
  quickContinue: ['Продолжай', 'продолжай'],
  quickGood: ['Хорошо, продолжай', 'Хорошо, продолжай'],
  back: 'Агенты',
  menu: 'Меню',
  thisPhone: 'Этот телефон',
  close: 'Закрыть',
  done: 'Готово',
  notifications: 'Уведомления',
  pushWhen: 'Когда агент спрашивает или падает',
  pushBlocked: 'Запрещены. Разрешите уведомления для Kelp в приложении «Настройки» и вернитесь.',
  pushUnavailable: 'В этом браузере недоступно.',
  pushFailed: 'Не удалось изменить уведомления. Попробуйте ещё раз.',
  addToHome: 'Для уведомлений Kelp должен быть на экране «Домой» и подключён там: отсканируйте код в Kelp › Настройки › Телефон ещё раз и следуйте шагам.',
  disconnect: 'Отключить этот телефон…',
  disconnectAsk: mac => `Отключить этот телефон от ${mac || 'вашего Mac'}? Чтобы подключить снова, отсканируйте новый код в Kelp.`,
  disconnectYes: 'Отключить',
  cancel: 'Отменить',
  pick: 'Выберите агента слева',
  units: { m: ' мин', h: ' ч', d: ' д' },
};
const russian = /^ru\b/i.test(navigator.language ?? '');
const S = russian ? RU : EN;
document.documentElement.lang = russian ? 'ru' : 'en';

// Kelp's mark for an agent, so the state never reads by colour alone: a clock for a plan limit, nothing for an agent
// with nothing new (ready, or done and seen).
const markOf = a =>
  a.status === 'waiting' || a.status === 'error' ? a.status
  : a.limit ? 'limit'
  : a.status === 'idle' || (a.status === 'done' && !a.unread) ? '' : a.status;
const SVG = 'http://www.w3.org/2000/svg';
const markHref = kind => `/icons/marks.svg#${kind || 'idle'}`;
function iconNode(name, cls = '') {
  const svg = document.createElementNS(SVG, 'svg'), use = document.createElementNS(SVG, 'use');
  if (cls) svg.setAttribute('class', cls);
  svg.setAttribute('aria-hidden', 'true');
  use.setAttribute('href', markHref(name));
  svg.append(use);
  return svg;
}
const markNode = kind => iconNode(kind, 'mark');
/** The branch, where it says something: the main one, where most work, goes without saying. */
const branch = a => (a.workspace && !/^(main|master)$/.test(a.workspace) ? a.workspace : '');

const VERBS = { editing: 'edit', writing: 'write', reading: 'read', fetching: 'fetch', 'searching the web for': 'search' };
/** A permission as [what it asks to do, on what]: the command whole, so you see what you allow. Null if unread. */
function permit(ask) {
  const body = ask?.kind === 'permission' && ask.text.match(/^Allow (.+)\?$/s)?.[1];
  if (!body) return null;
  const verb = Object.keys(VERBS).find(v => body.startsWith(v + ' '));
  if (verb) return [S.asksTo[VERBS[verb]], body.slice(verb.length + 1)];
  // A tool's bare name ("Bash", "github: create_issue") is the tool it would use; anything else is a command.
  return [S.asksTo[/^[\w-]+(: [\w-]+)?$/.test(body) ? 'use' : 'run'], body];
}
/** A project's tile: its icon where the Mac has one, else its first two letters on a colour of its own. */
function tileNode(name, project) {
  const tile = el('span', 'tile', name.slice(0, 2).toUpperCase());
  tile.style.setProperty('--hue', [...name].reduce((hue, letter) => (hue * 31 + letter.charCodeAt(0)) % 360, 7));
  if (project?.icon) {
    iconOf(project.id).then(address => {
      if (!address) return;
      const image = new Image();
      image.src = address;
      image.alt = '';
      tile.classList.add('icon');
      tile.replaceChildren(image);
    });
  }
  return tile;
}
// ponytail: icons are asked for again on each load, one at a time; keep them in the phone if the list gets long.
const icons = new Map();
let asking = Promise.resolve();
function iconOf(project) {
  if (!icons.has(project)) icons.set(project, asking = asking.then(() => kelp.icon(project)).catch(() => null));
  return icons.get(project);
}

const $ = id => document.getElementById(id);
const el = (tag, cls, ...children) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  node.append(...children.filter(Boolean));
  return node;
};
const set = (node, text) => { if (node.textContent !== text) node.textContent = text; };
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

let mac = '';
let projects = [], kinds = [];   // every project of the Mac and what can be started there, where the Mac says
let stops = false;                // whether the Mac can stop a working agent
let agents = new Map();
let paired = false;
let online = true;
let open = null;          // the agent on screen: {id, reply, shown, gone}
let sending = false;
const busy = new Map();   // agent id → 'flight' (answer on its way) | 'sent' (answered, its event not here yet)
const notes = new Map();  // agent id → the line under its Allow and Deny
const rowEls = new Map();

// ---- screens

function screen(name) {
  const body = document.body, was = body.dataset.screen;
  // Back to the list: the agent slides out to the right as iOS pops a view, then leaves the layout.
  if (was === 'agent' && name === 'list' && !reduceMotion.matches && !swiped && !wide.matches) {
    body.classList.add('popping');
    clearTimeout(screen.popped);
    screen.popped = setTimeout(() => body.classList.remove('popping'), 420);
  } else {
    body.classList.remove('popping');
  }
  body.dataset.screen = name;
  $('list').inert = name === 'agent' && !wide.matches;
  if (name === 'agent') for (const wake of lenses) wake();
  if (swiped) {   // the swipe left both panes where it ended: they go back to their places now the agent is gone
    swiped = false;
    $('agent').style.transform = $('list').style.transform = '';
  }
}
let swiped = false;   // the agent left by a swipe back, so it has no pop to play
const lenses = [];    // each wakes its lens, which sleeps while the agent isn't on screen

/** The screen before the agents. how: 'wait' only the words, 'install' the steps to the Home Screen, else a way to
    give this page a pairing link. */
function showPair(text, how = text === S.connecting ? 'wait' : 'ask') {
  paired = reaching = false;
  clearTimeout(retry);
  stream?.close();
  for (const d of document.querySelectorAll('dialog[open]')) d.close();
  $('pair-text').textContent = text;
  $('pair-note').textContent = '';
  $('pair-steps').hidden = $('pair-copy').hidden = $('pair-here').hidden = how !== 'install';
  $('pair-paste').hidden = how !== 'ask';
  $('pair-form').hidden = true;
  screen('pair');
}
let pending = null;   // a code this page came with while it already held a pairing: used if the Mac dropped that one
kelp.on.unpaired = () => (pending ? usePair(pending) : showPair(S.scanAgain));

function usePair(code) {
  pending = null;
  forget();
  showPair(S.connecting);
  kelp.pair(decoded(code), device()).then(sync, e => showPair(e.status === 0 ? S.failed('') : S.scanAgain));
}
$('pair-copy').onclick = () => navigator.clipboard.writeText(location.href).then(
  () => { $('pair-note').textContent = S.copied; }, () => { $('pair-note').textContent = location.href; });
$('pair-here').onclick = () => usePair(codeIn(location.hash));
function given(text) {
  const code = codeIn(text.trim());
  if (code) usePair(code);
  else $('pair-note').textContent = S.badLink;
}
// The clipboard, with the system's own "Paste" asked; where it can't be read, a field to paste into by hand.
$('pair-paste').onclick = () => navigator.clipboard.readText().then(given, () => {
  $('pair-form').hidden = false;
  $('pair-link').focus();
});
$('pair-form').onsubmit = e => { e.preventDefault(); given($('pair-link').value); };

function route() {
  if (!paired) return;
  const id = decoded(location.hash.slice(1));
  if (!id) {
    open = null;
    screen('list');
  } else if (open?.id !== id) {
    open = { id };
    $('a-reply').replaceChildren();
    $('send-error').textContent = '';
    $('text').value = sessionStorage.getItem('draft:' + id) ?? '';
    screen('agent');
    grow();
    $('a-body').scrollTop = 0;
    kelp.read(id).catch(() => {});
    loadOpen();
  }
  render();
}
// A pairing link opened in a page that is already loaded only changes the hash.
addEventListener('hashchange', () => {
  const code = codeIn(location.hash);
  if (code) start(code);
  else route();
});

// ---- data

/** Keeps an agent that came with its lastReply (GET /api/agents/{id}). */
function take(raw) {
  agents.set(raw.id, kelp.agentFrom(raw));
  if (open?.id === raw.id) [open.reply, open.turns] = [raw.lastReply ?? null, Array.isArray(raw.turns) && raw.turns.length ? raw.turns : null];
}

// The page names its version when the Mac serves it; the agents' list names the one the Mac has now. A page left open
// while Kelp updated loads again, once for each version, so a Mac that keeps serving another can't keep it reloading.
const servedAs = document.querySelector('meta[name="kelp-page"]')?.content;
function newerPage(page) {
  if (!servedAs || !page || page === servedAs || sessionStorage.getItem('reloaded-for') === page) return false;
  sessionStorage.setItem('reloaded-for', page);
  location.reload();
  return true;
}

async function refresh() {
  const data = await kelp.list();
  mac = data.mac ?? '';
  [projects, kinds, stops] = [data.projects ?? [], data.kinds ?? [], data.stops === true];
  if (newerPage(data.page)) return;
  agents = new Map(data.agents.map(a => [a.id, kelp.agentFrom(a)]));
  busy.clear();
  if (!paired) {
    paired = true;
    route();
    resubscribe();
  }
  render();
  if (open) loadOpen();
}

async function loadOpen() {
  const mine = open;
  try {
    const raw = await kelp.get(mine.id);
    if (open === mine) take(raw);
  } catch (e) {
    if (open === mine && e.status === 404) {
      mine.gone = true;
      agents.delete(mine.id);
    }
  }
  render();
}

function upsert(raw) {
  const a = kelp.agentFrom(raw), old = agents.get(a.id);
  agents.set(a.id, a);
  if (busy.get(a.id) === 'sent') busy.delete(a.id);
  if (!a.ask) notes.delete(a.id);
  if (open?.id === a.id) {
    if (old?.statusAt !== a.statusAt) loadOpen();
    if (a.unread && document.visibilityState === 'visible') kelp.read(a.id).catch(() => {});
  }
  render();
}

// The stream, and the list again each time it opens: the server doesn't resend what happened while it was down.
let stream, retry, delay = 1000;

function sync() {
  clearTimeout(retry);
  stream?.close();
  const mine = stream = kelp.events();
  mine.onopen = () => refresh().then(() => { delay = 1000; setOnline(true); }, lost);
  // A probe tells why it broke: 401 shows pairing, anything else is the Mac out of reach.
  mine.onerror = () => { mine.close(); if (stream === mine) refresh().then(() => lost(), lost); };
  mine.addEventListener('agent', e => upsert(JSON.parse(e.data)));
  mine.addEventListener('removed', e => {
    const { id } = JSON.parse(e.data);
    agents.delete(id);
    if (open?.id === id) open.gone = true;
    render();
  });
}

function lost(error) {
  stream?.close();
  if (error?.status === 401) return;
  // A new pairing link while the old Mac is out of reach: maybe it's another Mac now. Tried once; if it fails, the old one.
  if (error && pending) {
    const code = pending;
    pending = null;
    return kelp.pair(decoded(code), device()).then(sync, () => lost(error));
  }
  // Launched while the Mac sleeps: nothing to list yet, so say so (and keep a way to pair again) while it retries.
  if (error && !paired && !reaching) { showPair(S.cantReach(mac)); reaching = true; }
  if (error) setOnline(false);
  clearTimeout(retry);
  retry = setTimeout(sync, delay);
  delay = Math.min(delay * 2, 30000);
}

function setOnline(value) {
  if (online === value) return;
  online = value;
  render();
}

// iOS stops the page in the background: start over when it's seen again, or when the network is back.
let reaching = false;   // paired, but the Mac hasn't answered since launch
const again = () => { if (paired || reaching) { delay = 1000; sync(); } };
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') again(); });
addEventListener('online', again);

// ---- answers

async function choose(id, answer) {
  const question = agents.get(id)?.ask?.text;
  if (question == null || busy.has(id) || !online) return;
  busy.set(id, 'flight');
  notes.delete(id);
  render();
  try {
    const result = await kelp.choose(id, answer, question);
    if (result?.ok === false) {
      busy.delete(id);
      notes.set(id, S.changed);
      await kelp.get(id).then(take, () => {});
    } else if (agents.get(id)?.ask?.text === question) {
      // The page doesn't change the status itself: the buttons stay off until the agent's event says what happened.
      busy.set(id, 'sent');
      setTimeout(() => { if (busy.get(id) === 'sent') { busy.delete(id); render(); } }, 10000);
    } else {
      busy.delete(id);
    }
  } catch (e) {
    busy.delete(id);
    if (e.status !== 401) notes.set(id, e.message || S.failed(mac));
  }
  render();
}

/** Sends once and never again by itself: a second try could type the text twice. */
async function send(text, fromField) {
  const id = open?.id;
  if (!id || !text.trim() || sending) return;
  sending = true;
  $('send-error').textContent = '';
  renderAgent();
  try {
    await kelp.reply(id, text);
    if (fromField) {
      sessionStorage.removeItem('draft:' + id);
      if (open?.id === id) { $('text').value = ''; grow(); }
    }
  } catch (e) {
    if (open?.id === id && e.status !== 401) $('send-error').textContent = e.message || S.failed(mac);
  }
  sending = false;
  renderAgent();
}

let stopping = false;
async function stop() {
  const id = open?.id;
  if (!id || stopping) return;
  stopping = true;
  renderAgent();
  try {
    await kelp.stop(id);
  } catch (e) {
    if (open?.id === id && e.status !== 401) $('send-error').textContent = e.message || S.failed(mac);
  }
  stopping = false;
  renderAgent();
}

// ---- drawing

const rank = a =>
  a.status === 'waiting' ? 0
  : a.status === 'error' || a.limit ? 1
  : a.status === 'done' && a.unread ? 2
  : a.status === 'working' ? 3 : 4;

function ago(at) {
  const s = (Date.now() - Date.parse(at)) / 1000;
  if (!(s >= 60)) return Number.isNaN(s) ? '' : S.now;
  return s < 3600 ? `${s / 60 | 0}${S.units.m}` : s < 86400 ? `${s / 3600 | 0}${S.units.h}` : `${s / 86400 | 0}${S.units.d}`;
}


function answerButton(id, answer, label, primary) {
  const button = el('button', primary ? 'primary' : '', label);
  button.type = 'button';
  button.disabled = busy.has(id) || !online;
  button.onclick = () => choose(id, answer);
  return button;
}

function row(a) {
  let li = rowEls.get(a.id);
  if (!li) rowEls.set(a.id, li = el('li', 'row'));
  const time = ago(a.statusAt), note = notes.get(a.id);
  const sig = JSON.stringify([a, time, note, busy.has(a.id), online]);
  if (li.sig === sig) return li;
  li.sig = sig;

  const word = S.status[a.status];
  // What it says, as the sidebar does: "Asks: …", "Failed: …", the command it runs as a chip, else its summary.
  const asked = permit(a.ask);
  const lead = asked ? [asked[0], '', 'asks']
    : a.ask ? [S.asks, a.ask.text, 'asks']
    : a.limit ? [S.limitLead, S.limitShort(a.limit.kind, a.limit.resets), '']
    : a.status === 'error' && a.summary ? [S.failedLead, a.summary, 'failed'] : null;
  const says = lead ? el('span', 'says', el('span', `lead ${lead[2]}`, lead[0]), lead[1] && ` ${lead[1]}`)
    : a.running ? el('span', 'chip', iconNode('term'), a.running)
    : a.summary ? el('span', 'says', a.summary) : null;
  const link = el('a', 'open',
    markNode(markOf(a)),
    el('span', 'title', a.title || a.agentName || ''),
    a.unread && el('span', 'dot'),
    el('span', 'time', time),
    branch(a) && el('span', 'place', iconNode('branch'), el('span', '', branch(a))),
    says,
    asked && el('code', 'command', asked[1]),
    a.ask?.kind === 'question' && el('span', 'go', S.answer));
  link.href = '#' + encodeURIComponent(a.id);
  link.setAttribute('aria-label', [a.title, word, a.project, a.unread && S.unread].filter(Boolean).join(', '));
  li.dataset.status = a.status;
  li.dataset.mark = markOf(a);
  li.classList.toggle('unread', !!a.unread);
  li.replaceChildren(link);
  if (a.ask?.kind === 'permission') {
    li.append(el('div', 'answer', answerButton(a.id, 'deny', S.deny), answerButton(a.id, 'allow', S.allow, true)));
  }
  if (note) li.append(el('p', 'note', note));
  return li;
}

function renderList() {
  for (const [id, li] of rowEls) li.classList.toggle('current', open?.id === id);   // the one beside the list
  set($('mac'), mac || 'Kelp');
  set($('mac-inline'), mac || 'Kelp');
  $('offline').hidden = online;
  set($('offline-text'), S.cantReach(mac));
  $('list').classList.toggle('stale', !online);
  // How many need you, work and are done, as the top of Kelp's sidebar says it.
  const all = [...agents.values()];
  const counted = { waiting: a => a.status === 'waiting', working: a => a.status === 'working', done: a => a.status === 'done' && a.unread };
  const counts = Object.entries(counted).map(([kind, is]) => [kind, all.filter(is).length]).filter(([, n]) => n);
  const sig = JSON.stringify(counts);
  if ($('counts').sig !== sig) {
    $('counts').sig = sig;
    $('counts').replaceChildren(...counts.map(([kind, n]) => {
      const one = el('span', '', markNode(kind), el('b', '', String(n)), ' ' + S.counts[kind](n));
      one.dataset.mark = kind;
      return one;
    }));
  }
  $('counts').hidden = !counts.length;
  $('empty').hidden = agents.size > 0;
  set($('empty'), S.empty(mac));

  // Each project with its agents, the one whose agent needs you first; then the projects with none, to start one in.
  const sorted = all.sort((a, b) => rank(a) - rank(b) || Date.parse(b.statusAt) - Date.parse(a.statusAt));
  for (const [id, li] of rowEls) if (!agents.has(id)) { li.remove(); rowEls.delete(id); }
  const known = new Map(projects.map(p => [p.id, p])), busyOnes = new Map();
  for (const a of sorted) {
    const key = a.projectId ?? 'named:' + (a.project ?? '');
    if (!busyOnes.has(key)) busyOnes.set(key, { key, name: a.project ?? '', project: known.get(a.projectId), its: [] });
    busyOnes.get(key).its.push(a);
  }
  const shown = [...busyOnes.values(), ...projects.filter(p => !busyOnes.has(p.id)).map(p => ({ key: p.id, name: p.name, project: p, its: [] }))];
  for (const [key, group] of groupEls) if (!shown.some(one => one.key === key)) { group.li.remove(); groupEls.delete(key); }
  const same = (parent, nodes) => nodes.length === parent.children.length && nodes.every((node, i) => node === parent.children[i]);
  const focused = document.activeElement, list = $('rows');
  const groups = shown.map(one => {
    const group = groupOf(one);
    // The quiet ones (paused, ended, idle, done and seen) fold into one line once there are two of them.
    const quiet = one.its.filter(a => rank(a) === 4 && a.status !== 'working');
    const folded = quiet.length > 1 && !unfolded.has(one.key);
    const rows = (folded ? one.its.filter(a => !quiet.includes(a)) : one.its).map(row);
    if (quiet.length > 1) {
      const tally = {};
      for (const a of quiet) tally[S.quiet[a.status] ?? S.quiet.idle] = (tally[S.quiet[a.status] ?? S.quiet.idle] ?? 0) + 1;
      const parts = Object.entries(tally).map(([word, n]) => `${n} ${word}`).join(', ');
      set(group.fold.firstChild.lastChild, folded ? S.more(quiet.length, parts) : S.fewer);
      group.fold.firstChild.setAttribute('aria-expanded', String(!folded));
      rows.push(group.fold);
    }
    group.li.classList.toggle('idle', !one.its.length);
    group.add.hidden = !(one.project && kinds.length);
    group.add.disabled = !online;
    if (!same(group.ul, rows)) group.ul.replaceChildren(...rows);
    return group.li;
  });
  if (!same(list, groups)) list.replaceChildren(...groups);
  if (list.contains(focused) && document.activeElement !== focused) focused.focus({ preventScroll: true });
}

const groupEls = new Map();   // project → {li, ul, add, fold}
const unfolded = new Set();   // projects whose quiet agents are shown
function groupOf({ key, name, project }) {
  let group = groupEls.get(key);
  if (!group) {
    const ul = el('ul', 'glass'), add = el('button', 'icon', iconNode('plus'));
    add.type = 'button';
    add.setAttribute('aria-label', S.newIn(name));
    add.onclick = () => openStart(project);
    const toggle = el('button', 'fold', iconNode('back'), el('span'));
    toggle.type = 'button';
    toggle.onclick = () => { unfolded.has(key) ? unfolded.delete(key) : unfolded.add(key); renderList(); };
    const head = el('h2', 'project', name && tileNode(name, project), el('span', 'name', name || S.other), add);
    groupEls.set(key, group = { ul, add, fold: el('li', 'more', toggle), li: el('li', 'group', head, ul) });
  }
  return group;
}

// ---- starting an agent in a project

let startIn = null;
function openStart(project) {
  startIn = project;
  set($('start-title'), S.newIn(project.name));
  $('start-kind').replaceChildren(...kinds.map(kind => { const option = el('option', '', kind.name); option.value = kind.id; return option; }));
  // The agent this phone started last, else the one Kelp starts by default (claude, unless the Mac names another).
  const usual = [localStorage.getItem('kind'), kinds.find(kind => kind.default)?.id, 'claude'].find(id => kinds.some(kind => kind.id === id));
  if (usual) $('start-kind').value = usual;
  $('start-error').textContent = '';
  $('start').showModal();
  $('start-text').focus();
}
$('start-no').onclick = () => $('start').close();
$('start-form').onsubmit = async e => {
  e.preventDefault();
  const text = $('start-text').value.trim();
  if (!text || $('start-yes').disabled) return;
  $('start-yes').disabled = true;
  try {
    const { id } = await kelp.start(startIn.id, $('start-kind').value, text);
    localStorage.setItem('kind', $('start-kind').value);
    $('start-text').value = '';
    $('start').close();
    await refresh().catch(() => {});
    location.hash = encodeURIComponent(id);
  } catch (error) {
    $('start-error').textContent = error.message || S.notStarted;
  }
  $('start-yes').disabled = false;
};

/** A conversation's turns: what you asked, what the agent did, what it said. */
function talk(turns) {
  return turns.map(turn =>
    turn.role === 'user' ? el('p', 'asked', String(turn.text ?? ''))
    : turn.role === 'did' ? el('p', 'did', String(turn.text ?? ''))
    : el('div', 'said', ...kelp.replyNodes(turn.text)));
}

function renderAgent() {
  if (!open) return;
  const a = agents.get(open.id);
  const ended = open.gone || a?.status === 'exited';
  const off = !online || busy.has(open.id);

  set($('a-title'), a?.title || a?.agentName || '');
  // Its state in the title band: the mark and the word, then who and where.
  const kind = !a ? '' : a.status === 'done' ? 'done' : markOf(a);   // a seen Done keeps its ✓ here
  $('a-where').dataset.mark = kind;
  if ($('a-mark').getAttribute('href') !== markHref(kind)) $('a-mark').setAttribute('href', markHref(kind));
  set($('a-word'), !a ? '' : a.limit ? S.limitWord(a.limit.kind) : S.status[a.status]);
  const who = a ? [a.agentName, a.project, branch(a)].filter(Boolean) : [];
  set($('a-place'), who.length ? '· ' + who.join(' · ') : '');
  const calls = !!a?.ask && !ended;
  $('agent').classList.toggle('calls', calls);
  const working = a?.status === 'working' && !ended;
  $('stop').hidden = !(stops && working);
  $('stop').disabled = stopping || !online;

  $('a-offline').hidden = online;
  set($('a-offline-text'), S.cantReach(mac));

  $('a-limit').hidden = !a?.limit;
  if (a?.limit) {
    const at = a.continueAt && new Date(a.continueAt).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    set($('a-limit'), S.limit(a.limit.kind, a.limit.resets) + (at ? S.continues(at) : ''));
  }

  // A permission: what it would do, whole, with Allow and Deny. A question: the terminal's last line, the prompt answers.
  const asked = permit(a?.ask), question = calls && a.ask.kind === 'question';
  $('a-ask').hidden = !calls || question;
  set($('a-ask-lead'), asked ? asked[0] : S.asks);
  set($('a-ask-text'), asked ? asked[1] : a?.ask?.text ?? '');
  $('a-ask-buttons').hidden = a?.ask?.kind !== 'permission';
  $('a-question').hidden = !question;
  set($('a-question-text'), question ? a.ask.text : '');
  $('answer-lead').hidden = !question;
  set($('answer-lead-text'), question ? S.answerTo(a.agentName) : '');
  $('composer').classList.toggle('answering', question);
  text.placeholder = question ? S.answer : working ? S.whileWorking : S.message;
  $('a-live').hidden = !working;
  set($('a-live-text'), working ? a.running || a.summary || S.status.working : '');
  $('a-live').classList.toggle('running', !!a?.running);
  tick();
  $('a-allow').disabled = $('a-deny').disabled = off;
  set($('a-ask-note'), notes.get(open.id) ?? '');

  // The whole conversation where the Mac has it, its end in view; else the last reply, from its start.
  const showing = open.turns ? JSON.stringify(open.turns) : open.reply;
  if (open.shown !== showing) {
    open.shown = showing;
    $('a-reply').classList.toggle('talk', !!open.turns);
    $('a-reply').replaceChildren(...(open.turns ? talk(open.turns) : kelp.replyNodes(open.reply)));
    if (open.turns) $('a-body').scrollTop = $('a-body').scrollHeight;
  }

  $('a-ended').hidden = !ended;
  $('composer').hidden = ended;
  $('quick').hidden = !(a && (a.status === 'done' || a.status === 'error') && !a.ask && !a.limit);
  $('send').disabled = $('quick-continue').disabled = $('quick-good').disabled = sending || !online;
}

/** How long it has been on what it runs, as m:ss: the one thing on screen that moves each second. */
function tick() {
  const a = open && agents.get(open.id);
  if (!a || a.status !== 'working' || $('a-live').hidden) return;
  const s = Math.max(0, (Date.now() - Date.parse(a.statusAt)) / 1000 | 0);
  set($('a-live-time'), s >= 3600 ? `${s / 3600 | 0}h ${(s / 60 | 0) % 60}m` : `${s / 60 | 0}:${String(s % 60).padStart(2, '0')}`);
}
setInterval(tick, 1000);

function render() {
  renderList();
  renderAgent();
  if (paired && document.visibilityState === 'visible') {
    const waiting = [...agents.values()].filter(a => a.status === 'waiting').length;
    navigator.setAppBadge?.(waiting)?.catch(() => {});
  }
}
setInterval(() => paired && renderList(), 30000);   // the times in the rows

// ---- the field

const text = $('text');
function grow() {
  text.style.height = 'auto';
  text.style.height = text.scrollHeight + 'px';
}
text.addEventListener('input', () => {
  grow();
  if (!open) return;
  if (text.value) sessionStorage.setItem('draft:' + open.id, text.value);
  else sessionStorage.removeItem('draft:' + open.id);
});
$('send-form').addEventListener('submit', e => { e.preventDefault(); send(text.value, true); });
text.addEventListener('keydown', e => {
  if (e.key !== 'Enter' || e.shiftKey || e.isComposing || !keyboard.matches) return;
  e.preventDefault();
  $('send-form').requestSubmit();
});
// Escape goes back to the list, as the back button does, unless a sheet is open (it closes that itself).
addEventListener('keydown', e => {
  if (e.key === 'Escape' && open && !document.querySelector('dialog[open]')) location.hash = '';
});
// The window crossed the width: the list beside the agent, or under it again.
wide.addEventListener('change', () => screen(document.body.dataset.screen));
$('quick-continue').onclick = () => send(S.quickContinue[1]);
$('quick-good').onclick = () => send(S.quickGood[1]);
$('a-allow').onclick = () => open && choose(open.id, 'allow');
$('a-deny').onclick = () => open && choose(open.id, 'deny');
$('back').onclick = () => { location.hash = ''; };
$('stop').onclick = stop;

// The keyboard covers the bottom of the layout, not of what is seen: the page takes the height that is seen.
const seen = window.visualViewport;
function fit() {
  document.documentElement.style.setProperty('--seen', seen.height + 'px');
  if (seen.scale === 1) scrollTo(0, 0);
}
// Liquid Glass with a lens. Safari takes no SVG filter in backdrop-filter, so a pane shows a copy of what scrolls
// under it, kept in place, and the #lens filter of index.html bends that copy at the rim.
// The copy keeps its ids for app.css: each pane stands after its source, so $() still finds the source.
function lens(pane, source) {
  if (matchMedia('(prefers-reduced-transparency: reduce), (prefers-contrast: more)').matches) return;
  const copy = el('div'), view = el('div', 'lens', copy);
  view.style.filter = 'url(#lens)';   // from here: in app.css the address would be read against app.css
  view.setAttribute('aria-hidden', 'true');
  copy.inert = true;
  pane.classList.add('lensed');
  pane.prepend(view);
  // ponytail: placed on every frame (two rects a pane) while the agent is on screen, which also keeps it in step with a
  // scroll; watch the source's scroller and layout instead if this ever shows in a profile.
  // What changed under it is copied once a frame at most, and not at all while the agent isn't on screen.
  let was = '', stale = true, awake = false;
  const place = () => {
    if (document.body.dataset.screen !== 'agent') { awake = false; return; }
    requestAnimationFrame(place);
    if (stale) { stale = false; was = ''; copy.replaceChildren(source.cloneNode(true)); }
    const at = pane.getBoundingClientRect(), from = source.getBoundingClientRect(), twin = copy.firstChild;
    if (!twin || !at.width) return;
    const now = [from.left - at.left, from.top - at.top, from.width, from.height, source.scrollTop].join();
    if (now === was) return;
    was = now;
    copy.style.transform = `translate(${from.left - at.left}px, ${from.top - at.top}px)`;
    twin.style.width = from.width + 'px';
    twin.style.height = from.height + 'px';
    twin.scrollTop = source.scrollTop;
  };
  new MutationObserver(() => { stale = true; })
    .observe(source, { childList: true, subtree: true, characterData: true, attributes: true });
  const wake = () => { if (!awake) { awake = true; requestAnimationFrame(place); } };
  lenses.push(wake);
  wake();
}
lens($('a-ask'), $('a-body'));
lens($('send-form'), $('a-body'));

// The terminal scrolls under the glass dock: its last line stops above it.
new ResizeObserver(() => $('a-card').style.setProperty('--dock', $('dock').offsetHeight + 'px')).observe($('dock'));
seen?.addEventListener('resize', fit);
seen?.addEventListener('scroll', fit);

// ---- iOS motion

// The large title: once it scrolls under the bar, the bar shows the name small, in its middle.
new IntersectionObserver(([seen]) => $('list').classList.toggle('scrolled', !seen.isIntersecting),
  { root: $('list'), rootMargin: '-64px 0px 0px 0px' }).observe($('mac'));

// Back from the screen's left edge, as a pushed view goes back. Safari has its own edge swipe (it goes back through
// the hash), so only the Home Screen app, which has none, gets this one.
if (standalone) {
  const pane = $('agent'), under = $('list');
  let from = null;
  pane.addEventListener('touchstart', e => {
    const t = e.touches[0];
    from = e.touches.length === 1 && t.clientX < 24 ? { x: t.clientX, y: t.clientY, at: e.timeStamp, dx: 0, on: false } : null;
  }, { passive: true });
  pane.addEventListener('touchmove', e => {
    if (!from) return;
    const t = e.touches[0], dx = t.clientX - from.x;
    if (!from.on && Math.abs(t.clientY - from.y) > Math.abs(dx)) { from = null; return; }   // a scroll, not a swipe
    from.on = true;
    from.dx = Math.max(0, dx);
    const share = from.dx / innerWidth;
    pane.style.transition = under.style.transition = 'none';
    pane.style.transform = `translateX(${from.dx}px)`;
    under.style.transform = `translateX(${-30 * (1 - share)}%)`;
  }, { passive: true });
  pane.addEventListener('touchend', e => {
    if (!from?.on) { from = null; return; }
    const fast = from.dx / Math.max(1, e.timeStamp - from.at) > 0.5, back = from.dx > innerWidth / 3 || fast;
    from = null;
    pane.style.transition = under.style.transition = '';
    pane.style.transform = back ? 'translateX(100%)' : '';
    under.style.transform = back ? 'translateX(0)' : '';
    if (!back) return;
    const leave = e => {
      if (e && e.target !== pane) return;   // a transition of something inside it, not of the pane
      pane.removeEventListener('transitionend', leave);
      clearTimeout(late);
      swiped = true;
      location.hash = '';
    };
    pane.addEventListener('transitionend', leave);
    const late = setTimeout(leave, 500);   // a pane already at the edge has no transition to end
  });
}

// ---- notifications

const pushable = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
// ponytail: an iPad asking for the desktop site calls itself a Mac and gets "not available" in place of the hint.
const needsHome = ios && !standalone;   // Web Push on iOS exists only for a page on the Home Screen
// Registered even where there is no push: it also keeps the page for a launch with no network.
const registration = 'serviceWorker' in navigator ? navigator.serviceWorker.register('/sw.js').catch(() => null) : null;

async function subscription() {
  const reg = await registration;
  return reg ? reg.pushManager.getSubscription() : null;
}

/** Each launch sends the subscription the browser already has: that survives new keys and a reinstalled Kelp. */
function resubscribe() {
  subscription().then(sub => sub && kelp.subscribe(sub.toJSON())).catch(() => {});
}

async function pushOff() {
  const sub = await subscription();
  if (!sub) return;
  await kelp.unsubscribe(sub.endpoint);
  await sub.unsubscribe();
}

async function renderPush(problem) {
  const toggle = $('push-toggle');
  let state = S.pushWhen, can = true, isOn = false;
  if (needsHome) [state, can] = [S.addToHome, false];
  else if (!pushable || !(await registration)) [state, can] = [S.pushUnavailable, false];
  else if (Notification.permission === 'denied') [state, can] = [S.pushBlocked, false];
  else isOn = !!(await subscription().catch(() => null));
  set($('push-state'), problem ? `${problem}` : state);
  toggle.hidden = !can;
  toggle.dataset.on = isOn ? '1' : '';
  toggle.checked = isOn;
}

$('push-toggle').onclick = async () => {
  const toggle = $('push-toggle');
  // Asking for permission has to be the first thing the tap does, or Safari refuses it.
  const asked = toggle.dataset.on ? null : Notification.requestPermission();
  toggle.disabled = true;
  let problem;
  try {
    if (!asked) await pushOff();
    else if (await asked === 'granted') {
      const { key } = await kelp.pushKey();
      const bytes = Uint8Array.from(atob(key.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
      const reg = await registration;
      const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: bytes });
      await kelp.subscribe(sub.toJSON());
    }
  } catch (e) {
    problem = e?.status === 0 ? S.failed(mac) : S.pushFailed;
  }
  toggle.disabled = false;
  renderPush(problem);
};

// A tapped notification, while the page is already open: the service worker says which agent.
navigator.serviceWorker?.addEventListener('message', e => {
  if (typeof e.data?.agent === 'string') location.hash = encodeURIComponent(e.data.agent);
});

if (needsHome && !localStorage.getItem('home-hint-closed')) $('home-hint').hidden = false;
$('home-hint-close').onclick = () => {
  localStorage.setItem('home-hint-closed', '1');
  $('home-hint').hidden = true;
};

// ---- menu

const menu = $('menu'), confirm = $('confirm');
$('menu-open').onclick = () => {
  set($('menu-mac'), mac || 'Kelp');
  $('menu-link').classList.toggle('off', !online);
  set($('menu-link-text'), online ? S.connected : S.outOfReach);
  renderPush();
  menu.showModal();
};
$('menu-close').onclick = () => menu.close();
for (const dialog of [menu, confirm, $('start')]) {
  dialog.addEventListener('click', e => { if (e.target === dialog) dialog.close(); });   // a tap outside
}
$('disconnect').onclick = () => {
  menu.close();
  $('confirm-text').textContent = S.disconnectAsk(mac);
  $('confirm-error').textContent = '';
  confirm.showModal();
};
$('confirm-no').onclick = () => confirm.close();
$('confirm-yes').onclick = async () => {
  $('confirm-yes').disabled = true;
  try {
    await pushOff().catch(() => {});
    await kelp.unpair();
    showPair(S.scanAgain);
  } catch (e) {
    if (e.status !== 401) $('confirm-error').textContent = e.message || S.failed(mac);
  }
  $('confirm-yes').disabled = false;
};

// ---- words that never change

for (const [id, words] of Object.entries({
  'a-allow': S.allow, 'a-deny': S.deny, 'a-ended': S.ended,
  'quick-continue': S.quickContinue[0], 'quick-good': S.quickGood[0],
  'menu-title': S.thisPhone, 'push-title': S.notifications, 'disconnect': S.disconnect,
  'confirm-no': S.cancel, 'confirm-yes': S.disconnectYes, 'home-hint-text': S.addToHome,
  'start-kind-label': S.agentKind, 'start-text-label': S.whatToDo,
  'pair-copy': S.copy, 'pair-here': S.here, 'pair-paste': S.paste, 'pair-go': S.connect, 'pick': S.pick,
})) $(id).textContent = words;
for (const [id, words] of Object.entries({
  'menu-open': S.menu, 'back': S.back, 'send': S.send, 'home-hint-close': S.close, 'text': S.message, 'stop': S.stop,
  'menu-close': S.done, 'start-yes': S.startIt, 'start-no': S.cancel,
})) $(id).setAttribute('aria-label', words);
text.placeholder = S.message;
$('pair-steps').replaceChildren(...S.steps.map(step => el('li', '', step)));

// ---- start

function device() {
  const ua = navigator.userAgent;
  const what = ua.match(/iPhone|iPad|Android|Macintosh|Windows|Linux/)?.[0] ?? 'Phone';
  const how = ua.match(/CriOS|FxiOS|Edg|Firefox|Chrome|Safari/)?.[0] ?? 'browser';
  return `${what === 'Macintosh' ? 'Mac' : what}, ${{ CriOS: 'Chrome', FxiOS: 'Firefox', Edg: 'Edge' }[how] ?? how}`;
}

function start(code) {
  // A Home Screen app made from a pairing link starts with that link each time: once paired, it's an old one.
  if (code && kelp.paired()) {
    pending = code;
    forget();
    return sync();
  }
  if (!code) return sync();
  // In an iPhone's Safari the link stays in the address until you choose: a Home Screen app made now may start
  // with it and pair by itself, and Copy Pairing Link takes it there by hand.
  if (ios && !standalone) return showPair(S.install, 'install');
  usePair(code);
}
tuneLens();
follow();
start(codeIn(location.hash));
