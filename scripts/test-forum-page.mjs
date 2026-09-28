#!/usr/bin/env node
// The forum page in a real Chrome: the sign-in code step survives switching
// tabs, visibility, focus, freezing and a reload of the tab; the page answers
// an uninvited address exactly as an invited one; and nothing is stored in the
// browser before sign-in (Cookie Policy 2a).
//
//   node scripts/test-forum-page.mjs        (Node 22 or later, and Chrome)
//
// It serves this repository's forum page from a stub server on 127.0.0.1 that
// also answers as Supabase Auth, so no project, key or email is involved.
// Chrome is driven over the DevTools protocol with Node's own WebSocket.
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MEMBER = 'member@example.test';      // invited: the code works
const STRANGER = 'stranger@example.test';  // not invited: the Auth hook refuses it
const CODE = '123456';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = 0;
function check(name, ok, detail) {
  if (ok) console.log('ok - ' + name);
  else { failed++; console.log('not ok - ' + name + (detail === undefined ? '' : ': ' + JSON.stringify(detail))); }
  return ok;
}

// ---------------------------------------------------------------------------
// The stub: the site's files, a config pointing at itself, and Supabase Auth.
// ---------------------------------------------------------------------------
const calls = [];
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.jpg': 'image/jpeg' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://stub');
  const send = (status, body, type = 'application/json') => {
    res.writeHead(status, { 'content-type': type, 'cache-control': 'no-store' });
    res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  if (req.method === 'POST') {
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      let body = {};
      try { body = raw ? JSON.parse(raw) : {}; } catch { body = {}; }
      calls.push({ path: url.pathname, body });
      if (url.pathname === '/auth/v1/otp') {
        // What the hosted project answers: the hook refuses an address it has
        // no invitation for with 403.
        if (body.email === MEMBER) return send(200, {});
        return send(403, { code: 403, error_code: 'unexpected_failure',
          msg: 'This email address has not been invited to the Rebornly beta forum.' });
      }
      if (url.pathname === '/auth/v1/verify') {
        if (body.type === 'email' && body.email === MEMBER && body.token === CODE) {
          return send(200, { access_token: 'stub-access', refresh_token: 'stub-refresh', expires_in: 3600 });
        }
        return send(403, { code: 403, error_code: 'otp_expired', msg: 'Token has expired or is invalid' });
      }
      if (url.pathname === '/auth/v1/logout') return send(204, '');
      if (url.pathname === '/rest/v1/rpc/forum_me') {
        if (req.headers.authorization !== 'Bearer stub-access') return send(401, { message: 'JWT expired' });
        return send(200, { state: 'invited' });
      }
      return send(404, { message: 'not stubbed' });
    });
    return;
  }
  if (url.pathname === '/forum/config.js') {
    return send(200, `window.REBORNLY_FORUM_CONFIG = Object.freeze({ FORUM_URL: '${origin}', FORUM_KEY: 'sb_publishable_stub' });`,
      'text/javascript');
  }
  const path = decodeURIComponent(url.pathname.endsWith('/') ? url.pathname + 'index.html' : url.pathname);
  const file = normalize(join(ROOT, path));
  // Only the site's own files: nothing outside the checkout, no dot-folders.
  if (!file.startsWith(ROOT + sep) || path.split('/').some((part) => part.startsWith('.')) || !existsSync(file)) {
    return send(404, 'not found', 'text/plain');
  }
  let body = readFileSync(file);
  if (url.pathname === '/forum/' || url.pathname === '/forum/index.html') {
    // The page's own CSP, pointed at the stub instead of the hosted project.
    const html = body.toString('utf8');
    body = html.replace(/(http-equiv="Content-Security-Policy" content="[^"]*?)connect-src [^;"]*/, '$1connect-src ' + origin);
    if (body === html) return send(500, 'the forum page has no connect-src in its CSP', 'text/plain');
  }
  return send(200, body, TYPES[extname(file)] || 'application/octet-stream');
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
const profile = mkdtempSync(join(tmpdir(), 'forum-page-'));
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
ws.addEventListener('message', (event) => {
  const m = JSON.parse(event.data);
  if (m.id && pending.has(m.id)) {
    const { res, rej } = pending.get(m.id);
    pending.delete(m.id);
    if (m.error) rej(new Error(m.error.message)); else res(m.result);
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
await page('Page.enable');
await page('Runtime.enable');
const js = async (expression) => {
  const r = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || 'evaluation failed');
  return r.result.value;
};
async function until(expression, ms = 8000) {
  for (let waited = 0; waited < ms; waited += 100) {
    try { if (await js(expression)) return true; } catch { /* navigating */ }
    await sleep(100);
  }
  return false;
}
// Only forum.js builds these; the page's static no-JavaScript fallback also
// says "Beta forum", so a heading alone does not show that the code ran.
const signInStep = `document.querySelector('#app h1')?.textContent === 'Beta forum' && !!document.getElementById('email')`;
const codeStep = `document.querySelector('#app h1')?.textContent === 'Check your email' && !!document.getElementById('code')`;
const joinStep = `document.querySelector('#app h1')?.textContent === 'Welcome to the beta forum'`;
const view = () => js(`(async () => ({
  h1: document.querySelector('#app h1')?.textContent || '',
  path: location.pathname,
  hash: location.hash,
  text: document.querySelector('#app h1 + p')?.textContent || '',
  address: document.querySelector('#app strong')?.textContent || '',
  emailField: !!document.getElementById('code-email'),
  emailValue: document.getElementById('code-email')?.value ?? null,
  code: document.getElementById('code')?.value ?? null,
  status: document.querySelector('#app .status')?.textContent || '',
  keys: Object.keys(localStorage).map((k) => 'local:' + k).concat(Object.keys(sessionStorage).map((k) => 'session:' + k)),
  cookie: document.cookie,
  historyState: history.state,
  windowName: window.name,
  indexedDB: (await indexedDB.databases()).map((d) => d.name),
  caches: typeof caches === 'undefined' ? [] : await caches.keys(),
}))()`);
// Cookie Policy 2a: before sign-in nothing at all; after it, only the session.
async function stored() {
  const v = await view();
  const { cookies } = await cdp('Storage.getCookies');
  return { keys: v.keys, cookie: v.cookie, cookies: cookies.length, historyState: v.historyState,
    windowName: v.windowName, indexedDB: v.indexedDB, caches: v.caches };
}
const nothingStored = (s) => s.keys.length === 0 && s.cookie === '' && s.cookies === 0 && s.historyState === null
  && s.windowName === '' && s.indexedDB.length === 0 && s.caches.length === 0;
async function type(selector, text) {
  await js(`(() => { const el = document.querySelector(${JSON.stringify(selector)}); el.focus(); el.select?.(); })()`);
  await page('Input.insertText', { text });
}
const click = (expression) => js(`(${expression}).click()`);
const control = (label) => `[...document.querySelectorAll('#app button, #app a, #bar button')].find((b) => b.textContent.trim() === ${JSON.stringify(label)})`;
const submit = `document.querySelector('#app form button[type=submit]')`;
const otpCalls = () => calls.filter((c) => c.path === '/auth/v1/otp');
async function reload() {
  const before = await js('performance.timeOrigin');
  await page('Page.reload', { ignoreCache: true });
  return until(`performance.timeOrigin !== ${before} && document.readyState === 'complete'`);
}

try {
  // 1. The sign-in page stores nothing.
  await page('Page.navigate', { url: origin + '/forum/' });
  if (!check('the forum page shows the sign-in step', await until(signInStep), await view())) throw 0;
  check('nothing is stored in the browser before sign-in', nothingStored(await stored()), await stored());

  // 2. Asking for a code leads to the code step at #/code.
  await type('#email', ' Member@Example.test ');
  await click(submit);
  if (!check('asking for a code shows the code step', await until(codeStep), await view())) throw 0;
  let v = await view();
  const memberText = v.text;
  check('the code step has an address of its own, #/code', v.hash === '#/code', v);
  check('it names the address, lower-cased, and says a code is on its way',
    v.address === MEMBER && v.text.includes('a code is on its way') && !v.emailField, v);
  check('one code was asked for, for that address',
    otpCalls().length === 1 && otpCalls()[0].body.email === MEMBER && otpCalls()[0].body.create_user === true, calls);
  check('asking for a code stores nothing in the browser', nothingStored(await stored()), await stored());
  await type('#code', '12');

  // 3. Switching tabs, visibility and focus leave the code step alone.
  await js(`window.__seen = []; for (const [on, type] of [[document, 'visibilitychange'], [window, 'blur'],
    [window, 'focus'], [window, 'pagehide'], [window, 'pageshow'], [document, 'freeze'], [document, 'resume']]) {
    on.addEventListener(type, () => window.__seen.push(type + ':' + document.visibilityState)); }`);
  const other = await cdp('Target.createTarget', { url: 'about:blank' });
  await cdp('Target.activateTarget', { targetId: other.targetId });
  await until(`document.visibilityState === 'hidden'`, 3000);
  const hidden = await js('document.visibilityState');
  // A background tab is what Chrome freezes to save power.
  await page('Page.setWebLifecycleState', { state: 'frozen' });
  await sleep(300);
  await page('Page.setWebLifecycleState', { state: 'active' });
  await cdp('Target.activateTarget', { targetId });
  await until(`document.visibilityState === 'visible'`, 3000);
  await cdp('Target.closeTarget', { targetId: other.targetId });
  await js(`for (const [on, type] of [[window, 'blur'], [document, 'visibilitychange'], [window, 'focus'],
    [window, 'pagehide'], [window, 'pageshow']]) on.dispatchEvent(new Event(type));`);
  await sleep(500);
  const seen = await js('window.__seen.slice()');
  check('another tab in front hides the page, and bringing it back shows it', hidden === 'hidden'
    && seen.includes('visibilitychange:hidden') && seen.includes('visibilitychange:visible'), { hidden, seen });
  check('the page was frozen and resumed', seen.some((e) => e.startsWith('freeze')) && seen.some((e) => e.startsWith('resume')), seen);
  v = await view();
  check('after tabs, visibility, focus, freezing and resuming: still the code step',
    v.h1 === 'Check your email' && v.hash === '#/code' && v.address === MEMBER, v);
  check('the code typed so far is still there', v.code === '12', v);
  check('no new code was asked for', otpCalls().length === 1, calls);

  // 4. A reload (what Chrome does to a discarded or killed tab) keeps the step.
  if (!check('the tab reloaded', await reload())) throw 0;
  const back = await until(codeStep);
  v = await view();
  if (!check('after a reload of the tab: still the code step, not the sign-in step', back && v.hash === '#/code', v)) throw 0;
  check('it asks for the address with the code, and claims no code is on its way',
    v.emailField && v.emailValue === '' && v.code === '' && !v.text.includes('on its way'), v);
  check('the reload asked for no new code', otpCalls().length === 1, calls);
  check('the reloaded code step stores nothing in the browser', nothingStored(await stored()), await stored());

  // 5. The code from the first email signs in from the reloaded step.
  await type('#code-email', MEMBER);
  await type('#code', CODE);
  await click(submit);
  check('the first code signs in from the reloaded step', await until(joinStep), await view());
  const verify = calls.filter((c) => c.path === '/auth/v1/verify').at(-1);
  check('it verified that address and code', verify && verify.body.email === MEMBER && verify.body.token === CODE
    && verify.body.type === 'email', verify);
  v = await view();
  check('signed in, the page is at #/', v.hash === '#/', v);
  const signedIn = await stored();
  check('signed in, the only thing stored is the session in local storage',
    nothingStored({ ...signedIn, keys: signedIn.keys.filter((k) => k !== 'local:rebornly.forum.session') })
    && signedIn.keys.includes('local:rebornly.forum.session'), signedIn);

  // 6. A signed-in member who opens #/code goes on to the forum.
  await js(`location.hash = '#/code'`);
  check('a signed-in member at #/code is taken to #/', await until(`location.hash === '#/' && ${joinStep}`), await view());

  // 7. The wordmark keeps the member in the forum.
  await js(`location.hash = '#/rules'`);
  await until(`document.querySelector('#app h1')?.textContent === 'Forum rules'`);
  await click(`document.querySelector('.site-header a')`);
  const home = await until(`location.pathname === '/forum/' && location.hash === '#/' && ${joinStep}`);
  check('the wordmark leads to the forum\'s own start, not the website', home, await view().catch(() => 'navigated away'));

  // 8. After signing out: an uninvited address gets exactly the same answer.
  await click(control('Sign out'));
  check('signing out shows the sign-in step and clears the browser', await until(signInStep)
    && nothingStored(await stored()), await stored());
  await type('#email', STRANGER);
  await click(submit);
  check('an uninvited address also reaches the code step', await until(codeStep), await view());
  v = await view();
  check('its code step reads exactly as for an invited address', v.hash === '#/code' && v.address === STRANGER
    && v.status === '' && v.text.replace(STRANGER, 'X') === memberText.replace(MEMBER, 'X'), { v, memberText });
  check('the server was asked for its code, and refused it', otpCalls().at(-1).body.email === STRANGER, calls);
  check('it stores nothing in the browser either', nothingStored(await stored()), await stored());
  await click(control('Use another address'));
  check('"Use another address" goes back to the sign-in step at #/', await until(`${signInStep} && location.hash === '#/'`), await view());

  // 9. "I already have a code": no new code, no claim that one is on its way.
  const asked = otpCalls().length;
  await type('#email', 'other@example.test');
  await click(control('I already have a code'));
  await until(codeStep);
  v = await view();
  check('"I already have a code" opens the code step with the typed address, editable, and asks for no code',
    v.hash === '#/code' && v.emailField && v.emailValue === 'other@example.test' && otpCalls().length === asked, v);
  check('it does not say a code is on its way', !v.text.includes('on its way') && v.address === '', v);
  await type('#code', '000000');
  await click(submit);
  await until(`document.querySelector('#app .status')?.textContent.includes('do not match')`);
  v = await view();
  check('a wrong address or code there says both may be wrong, and stays on the code step',
    v.h1 === 'Check your email' && /address and code do not match/.test(v.status), v);
  await click(control('Ask for a new code'));
  check('"Ask for a new code" goes back to the sign-in step at #/', await until(`${signInStep} && location.hash === '#/'`), await view());

  // 10. A wrong code right after asking for one keeps the plain message.
  await type('#email', MEMBER);
  await click(submit);
  await until(codeStep);
  await type('#code', '000000');
  await click(submit);
  await until(`document.querySelector('#app .status')?.textContent.includes('wrong')`);
  v = await view();
  check('a wrong code says so and stays on the code step', v.h1 === 'Check your email' && /wrong or has expired/.test(v.status), v);
} catch (error) {
  if (error !== 0) check('the test ran to the end', false, String(error && error.stack || error));
}

console.log(failed ? `forum page tests: FAIL (${failed})` : 'forum page tests: PASS');
finish(failed ? 1 : 0);
