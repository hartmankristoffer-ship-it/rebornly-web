#!/usr/bin/env node
// DOLL-ID-01: the website's 404 page and its /.well-known files, in a real
// Chrome, served the way GitHub Pages serves them.
//
//   node scripts/test-site-pages.mjs        (Node 22 or later, and Chrome)
//
// A printed QR code opens https://rebornlyapp.com/d/RB-XXXXXX. The site has no
// page there, so GitHub Pages answers with /404.html, and that page shows the
// Doll view only for a Doll ID with a right check character. The checks:
//   - a right ID, in any letter case and with or without a trailing slash,
//     shows only "This doll is registered on Rebornly", the ID as printed and
//     "Rebornly is coming soon";
//   - a mistyped ID, a look-alike letter, a receipt number, any other path,
//     and every path without JavaScript, show "Page not found";
//   - the page makes no request beyond its document and its own images, and
//     stores nothing in the browser;
//   - the page's Content-Security-Policy names the sha256 of its one inline
//     script, and Chrome runs it under that policy with no violation;
//   - /.well-known/assetlinks.json and /.well-known/apple-app-site-association
//     are served and grant nothing: [] and {"applinks":{"details":[]}}.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
function check(name, ok, detail) {
  if (ok) console.log('ok - ' + name);
  else { failed++; console.log('not ok - ' + name + (detail === undefined ? '' : ': ' + JSON.stringify(detail))); }
  return ok;
}

// The Doll IDs every part of Rebornly agrees on (the app's DollCode, the
// database's security.doll_code_is_valid and this page).
const VALID = ['RB-DVP8B0', 'RB-HKYRKE', 'RB-RJGTKV', 'RB-DJ9XWC', 'RB-TTX466'];
const DOLL_VIEW = (id) => ['This doll is registered on Rebornly', id, 'Rebornly is coming soon'];
const NOT_FOUND = ['Page not found', 'There is no page at this address.', 'Back to the start page'];
const ASSETLINKS = '[]';
const AASA = '{"applinks":{"details":[]}}';

// ---------------------------------------------------------------------------
// The files themselves.
// ---------------------------------------------------------------------------
const html = readFileSync(join(ROOT, '404.html'), 'utf8');
const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/g)];
check('404.html has exactly one script, inline', scripts.length === 1 && scripts[0][1].trim() === '',
  scripts.map((s) => s[1]));
// The browser hashes the script's text after the HTML parser has turned every
// CRLF and lone CR into LF, so a CRLF checkout on Windows hashes the same.
const script = (scripts[0]?.[2] ?? '').replace(/\r\n?/g, '\n');
const digest = 'sha256-' + createHash('sha256').update(script, 'utf8').digest('base64');
const csp = /<meta http-equiv="Content-Security-Policy" content="([^"]*)">/.exec(html)?.[1] ?? '';
check('the CSP allows only that script, the page\'s own images and inline style, and no connection',
  csp === `default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; script-src '${digest}'; base-uri 'none'; form-action 'none'`,
  { csp, scriptHash: digest });
// Chrome below proves what the page does; this names what it must never reach
// for, including calls a CSP would not stop (storage, an image's address).
const FORBIDDEN = /fetch|XMLHttpRequest|sendBeacon|WebSocket|EventSource|import\s*\(|localStorage|sessionStorage|indexedDB|cookie|caches|serviceWorker|history\.|window\.name|innerHTML|outerHTML|insertAdjacentHTML|document\.write|\.src\b|\.href\b/g;
check('the script uses no network, storage or HTML-writing call', !script.match(FORBIDDEN), script.match(FORBIDDEN));
check('the page is kept out of search engines', html.includes('<meta name="robots" content="noindex">'));
const urls = [...html.matchAll(/\b(?:src|href)="([^"]*)"/g)].map((m) => m[1]);
check('every address in the page is absolute on this site (it is served at every depth)',
  urls.length > 0 && urls.every((u) => u.startsWith('/') && !u.startsWith('//')), urls);
check('the page does not link the invitation-only forum', !/\/forum/.test(html));
check('.nojekyll is there, so GitHub Pages publishes /.well-known', existsSync(join(ROOT, '.nojekyll')));
for (const [file, exact] of [['.well-known/assetlinks.json', ASSETLINKS], ['.well-known/apple-app-site-association', AASA]]) {
  let raw = null;
  try { raw = readFileSync(join(ROOT, file), 'utf8'); } catch { /* missing: the check below fails */ }
  let parsed;
  try { parsed = JSON.parse(raw); } catch (error) { parsed = String(error); }
  check(`${file} is JSON that grants nothing: exactly ${exact}`,
    raw !== null && raw.trim() === exact && JSON.stringify(parsed) === exact, raw ?? 'missing');
}

// ---------------------------------------------------------------------------
// A stub of GitHub Pages: a file is served as it is (an extensionless one as
// application/octet-stream, dot-folders included), a folder without its slash
// is redirected, and every other path gets /404.html with status 404.
// ---------------------------------------------------------------------------
const served = [];
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://stub');
  served.push(req.method + ' ' + url.pathname);
  const send = (status, body, type, extra = {}) => {
    res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store', ...extra });
    res.end(req.method === 'HEAD' ? undefined : body);
  };
  let path;
  try { path = decodeURIComponent(url.pathname); } catch { path = null; }
  const file = path === null ? null : normalize(join(ROOT, path.endsWith('/') ? path + 'index.html' : path));
  // Nothing outside the checkout, and not the checkout's own git metadata.
  const inside = file !== null && file.startsWith(ROOT + sep) && !/(^|[\\/])\.git($|[\\/])/.test(file.slice(ROOT.length));
  const stat = inside && existsSync(file) ? statSync(file) : null;
  if (stat?.isDirectory() && !path.endsWith('/')) return send(301, '', 'text/html', { location: url.pathname + '/' });
  if (stat?.isFile()) return send(200, readFileSync(file), TYPES[extname(file)] || 'application/octet-stream');
  return send(404, readFileSync(join(ROOT, '404.html')), TYPES['.html']);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = 'http://127.0.0.1:' + server.address().port;

// ---------------------------------------------------------------------------
// Chrome over the DevTools protocol.
// ---------------------------------------------------------------------------
const CANDIDATES = [process.env.CHROME, 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe', '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].filter(Boolean);
const CHROME = CANDIDATES.find((p) => existsSync(p));
if (!CHROME) { console.log('not ok - no Chrome found; set CHROME'); process.exit(1); }
const profile = mkdtempSync(join(tmpdir(), 'site-pages-'));
const chrome = spawn(CHROME, ['--headless=new', '--remote-debugging-port=0', '--user-data-dir=' + profile,
  '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync',
  '--disable-background-networking', '--disable-component-update', '--password-store=basic',
  '--use-mock-keychain', ...(process.env.CI ? ['--no-sandbox'] : []), 'about:blank'], { stdio: 'ignore' });
let finished = false;
const guard = setTimeout(() => { console.log('not ok - the test took over 90 s'); finish(1); }, 90000);
function finish(code) {
  if (finished) return;
  finished = true;
  clearTimeout(guard);
  try { chrome.kill(); } catch { /* gone */ }
  server.close();
  setTimeout(() => { try { rmSync(profile, { recursive: true, force: true }); } catch { /* locked */ } process.exit(code); }, 500);
}

let port = null;
for (let i = 0; i < 80 && !port; i++) {
  await sleep(250);
  try { port = readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0].trim(); } catch { /* starting */ }
}
if (!port) { console.log('not ok - Chrome did not start'); finish(1); }
const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.addEventListener('open', r, { once: true }); ws.addEventListener('error', j, { once: true }); });
let seq = 0;
const pending = new Map();
const listeners = new Set();
ws.addEventListener('message', (event) => {
  const m = JSON.parse(event.data);
  if (m.id && pending.has(m.id)) {
    const { res, rej } = pending.get(m.id);
    pending.delete(m.id);
    if (m.error) rej(new Error(m.error.message)); else res(m.result);
  } else if (m.method) {
    for (const listener of listeners) listener(m);
  }
});
const cdp = (method, params = {}, sessionId) => new Promise((res, rej) => {
  const id = ++seq;
  pending.set(id, { res, rej });
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
});

const { targetId } = await cdp('Target.createTarget', { url: 'about:blank' });
const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
const page = (method, params) => cdp(method, params, sessionId);
// Every request the tab makes, blocked ones included, and the document's status.
const requests = [];
let documentStatus = null;
listeners.add((m) => {
  if (m.sessionId !== sessionId) return;
  if (m.method === 'Network.requestWillBeSent') {
    requests.push({ method: m.params.request.method, url: m.params.request.url, type: m.params.type });
  }
  if (m.method === 'Network.responseReceived' && m.params.type === 'Document') documentStatus = m.params.response.status;
});
await page('Page.enable');
await page('Runtime.enable');
await page('Network.enable');
await page('Network.setCacheDisabled', { cacheDisabled: true });
// Records what the page's CSP refuses; DevTools adds this, not the page.
await page('Page.addScriptToEvaluateOnNewDocument', { source: `window.__violations = [];
  document.addEventListener('securitypolicyviolation', (e) => window.__violations.push(e.violatedDirective + ' ' + e.blockedURI));` });
const js = async (expression) => {
  const r = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'evaluation failed');
  return r.result.value;
};
const lines = (text) => text.split('\n').map((line) => line.trim()).filter(Boolean);

async function visit(path, { javascript = true } = {}) {
  await page('Emulation.setScriptExecutionDisabled', { value: !javascript });
  requests.length = 0;
  served.length = 0;
  documentStatus = null;
  const loaded = new Promise((r) => {
    const listener = (m) => {
      if (m.sessionId === sessionId && m.method === 'Page.loadEventFired') { listeners.delete(listener); r(true); }
    };
    listeners.add(listener);
    setTimeout(() => { listeners.delete(listener); r(false); }, 8000);
  });
  await page('Page.navigate', { url: origin + path });
  const ok = await loaded;
  await sleep(400); // room for anything the page might send late
  const { cookies } = await cdp('Storage.getCookies');
  const v = await js(`(async () => ({
    url: location.href,
    title: document.title,
    main: document.querySelector('main')?.innerText ?? '',
    body: document.body.innerText,
    notFoundShown: !document.getElementById('notFound').hidden,
    dollShown: !document.getElementById('doll').hidden,
    dollId: document.getElementById('dollId').textContent,
    violations: window.__violations || [],
    keys: Object.keys(localStorage).concat(Object.keys(sessionStorage)),
    cookie: document.cookie,
    historyState: history.state,
    windowName: window.name,
    indexedDB: (await indexedDB.databases()).map((d) => d.name),
    caches: typeof caches === 'undefined' ? [] : await caches.keys(),
  }))()`);
  return { ...v, loaded: ok, status: documentStatus, cookies: cookies.length, requests: requests.slice(), served: served.slice() };
}
// Only the document itself and the page's own images under /assets/branding/.
const onlyOwnImages = (v) => v.requests.length >= 1 && v.requests[0].type === 'Document' && v.requests[0].url === v.url
  && v.requests.slice(1).every((r) => r.method === 'GET' && r.url.startsWith(origin + '/assets/branding/'))
  && v.served.slice(1).every((s) => s.startsWith('GET /assets/branding/'));
const nothingStored = (v) => v.keys.length === 0 && v.cookie === '' && v.cookies === 0 && v.historyState === null
  && v.windowName === '' && v.indexedDB.length === 0 && v.caches.length === 0;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const brief = (v) => ({ url: v.url, title: v.title, main: lines(v.main), dollId: v.dollId, status: v.status,
  violations: v.violations, requests: v.requests, served: v.served });

try {
  // 1. A right Doll ID, as a QR code carries it and as someone types it.
  const shown = [
    ['/d/RB-DVP8B0', 'RB-DVP8B0'],
    ['/d/rb-hkyrke', 'RB-HKYRKE'],
    ['/d/RB-RJGTKV/', 'RB-RJGTKV'],
    ['/d/Rb-dJ9xWc', 'RB-DJ9XWC'],
    ['/d/rB-TTX466/', 'RB-TTX466'],
  ];
  check('the shown IDs are the shared vectors', same(shown.map(([, id]) => id), VALID));
  for (const [path, id] of shown) {
    const v = await visit(path);
    check(`${path} shows only the Doll view with ${id}`, v.loaded && same(lines(v.main), DOLL_VIEW(id))
      && v.dollShown && !v.notFoundShown && v.dollId === id && v.title === 'Rebornly', brief(v));
    check(`${path} is served with status 404, as GitHub Pages serves it`, v.status === 404, brief(v));
    check(`${path} runs under its CSP with no violation`, v.violations.length === 0, v.violations);
    check(`${path} makes no request beyond its document and own images`, onlyOwnImages(v), brief(v));
    check(`${path} stores nothing in the browser`, nothingStored(v), { keys: v.keys, cookie: v.cookie, cookies: v.cookies,
      historyState: v.historyState, windowName: v.windowName, indexedDB: v.indexedDB, caches: v.caches });
  }

  // 2. Everything else is a plain "Page not found".
  const notFound = [
    ['/d/RB-DVP8B1', 'the check character is wrong'],
    ['/d/RB-DVQ8B0', 'one character is wrong'],
    ['/d/RB-VDP8B0', 'two neighbours are swapped'],
    ['/d/RB-HKYRKF', 'the check character is wrong'],
    ['/d/RB-RJGTVK', 'the last two are swapped'],
    ['/d/RB-DVP8BO', 'a letter O stands for the zero (the page does not read look-alikes)'],
    // Letters outside the alphabet, each in an ID whose check sum would come
    // out right if the letter were let through: only the path's shape stops them.
    ['/d/RB-BPDEIF', 'it has an I'],
    ['/d/RB-PF3DSL', 'it has an L'],
    ['/d/RB-14OWRG', 'it has an O'],
    ['/d/RB-H0NUBY', 'it has a U'],
    ['/d/RB-TR-000123', 'it is a transfer receipt number'],
    ['/d/RB-DVP8B', 'it is five characters'],
    ['/d/RB-DVP8B00', 'it is seven characters'],
    ['/d/RBDVP8B0', 'the dash is missing'],
    ['/d/XB-DVP8B0', 'the prefix is not RB'],
    ['/d/RB-DVP8B0/x', 'something follows the ID'],
    ['/d/RB-DVP8B0//', 'two slashes follow the ID'],
    ['/x/RB-DVP8B0', 'the folder is not /d/'],
    ['/D/RB-DVP8B0', 'the folder is /D/, not /d/'],
    ['/d/', 'there is no ID'],
    ['/d/RB%2DDVP8B0', 'the dash is percent-encoded'],
    ['/d/%3Cscript%3E', 'it is markup'],
    ['/foo', 'it is any other path'],
  ];
  for (const [path, why] of notFound) {
    const v = await visit(path);
    check(`${path} shows "Page not found" (${why})`, v.loaded && same(lines(v.main), NOT_FOUND) && v.notFoundShown
      && !v.dollShown && v.dollId === '' && !/registered/i.test(v.body) && v.title === 'Page not found — Rebornly'
      && v.status === 404, brief(v));
    check(`${path} runs with no violation, no request beyond its own images, nothing stored`,
      v.violations.length === 0 && onlyOwnImages(v) && nothingStored(v), brief(v));
  }

  // 3. Without JavaScript even a right ID stays "Page not found": the page
  //    never claims a Doll unless the check has run.
  const noScript = await visit('/d/RB-DVP8B0', { javascript: false });
  check('without JavaScript /d/RB-DVP8B0 shows "Page not found"', noScript.loaded
    && same(lines(noScript.main), NOT_FOUND) && noScript.dollId === '' && noScript.title === 'Page not found — Rebornly',
    brief(noScript));

  // 4. The association files are served, as they are, from the dot-folder.
  for (const [path, exact, type] of [['/.well-known/assetlinks.json', ASSETLINKS, 'application/json'],
    ['/.well-known/apple-app-site-association', AASA, 'application/octet-stream']]) {
    const response = await fetch(origin + path, { redirect: 'manual' });
    const text = await response.text();
    let parsed;
    try { parsed = JSON.parse(text); } catch (error) { parsed = String(error); }
    check(`${path} is served with status 200 and grants nothing`, response.status === 200
      && (response.headers.get('content-type') || '').startsWith(type) && text.trim() === exact
      && JSON.stringify(parsed) === exact, { status: response.status, type: response.headers.get('content-type'), text });
  }
} catch (error) {
  check('the test ran to the end', false, String(error && error.stack || error));
}

console.log(failed ? `site page tests: FAIL (${failed})` : 'site page tests: PASS');
finish(failed ? 1 : 0);
