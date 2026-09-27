// WEB-02: the closed beta forum (rebornly-web #12).
//
// Plain JavaScript with no libraries, like the rest of the site. It talks to
// the forum's own Supabase project only: Supabase Auth for the email code, and
// the checked forum_* database functions for everything else. Whatever a
// member wrote is only ever put on the page as text (textContent), never as
// HTML. The one thing kept in the browser is the sign-in session, in local
// storage, so a member stays signed in on this device until they sign out.
(() => {
  'use strict';

  // Must equal forum.rules_version() in the migration; scripts/test-forum.sh
  // checks that the two agree.
  const RULES_VERSION = '1.0';
  const RULES = [
    'Be kind and respectful. No harassment, hate, threats or personal attacks.',
    'Keep to Rebornly, the beta and reborn dolls. Honest feedback is welcome, including criticism.',
    'Do not share anybody else\'s personal information, and think twice before sharing your own.',
    'No selling, advertising, fundraising or spam.',
    'Nothing illegal, and nothing you do not have the right to share.',
    'You must be 18 or older.',
    'Moderators may hide posts or suspend accounts that break these rules, and will tell you why. ' +
      'Use Report on a post that breaks them, or email support@rebornlyapp.com.',
  ];

  const config = window.REBORNLY_FORUM_CONFIG || {};
  const BASE = String(config.FORUM_URL || '').replace(/\/+$/, '');
  const KEY = String(config.FORUM_KEY || '');
  const STORE = 'rebornly.forum.session';
  const SUPPORT = 'support@rebornlyapp.com';

  const app = document.getElementById('app');
  const bar = document.getElementById('bar');

  const MESSAGES = {
    not_signed_in: 'Please sign in again.',
    not_member: 'You have not joined the forum yet.',
    suspended: 'Your forum account is suspended.',
    not_moderator: 'Only moderators can do that.',
    invalid_title: 'A title needs 3 to 120 characters, on one line.',
    invalid_body: 'Please write between 1 and 10,000 characters.',
    invalid_reason: 'Please give a reason of 3 to 500 characters.',
    invalid_email: 'That does not look like an email address.',
    invalid_name: 'Choose a name of 2 to 30 letters, numbers, spaces, dots, dashes or underscores. ' +
      'Names that look like the Rebornly team cannot be used.',
    name_taken: 'That name is already taken. Please choose another.',
    already_member: 'You have already joined the forum.',
    not_invited: 'This email address has not been invited to the forum.',
    adult_required: 'You need to be 18 or older to join.',
    rules_outdated: 'The forum rules have changed. Please reload the page and read them again.',
    team_only: 'Only the Rebornly team can start threads here.',
    not_found: 'This could not be found. It may have been removed.',
    locked: 'This thread is locked.',
    hidden: 'A post hidden by a moderator cannot be edited.',
    own_post: 'You cannot report your own post.',
    already_reported: 'You have already reported this post.',
    rate_limited: 'You are posting very quickly. Please wait a few minutes and try again.',
    cannot_suspend_moderator: 'A moderator cannot be suspended here.',
    read_only: 'The forum is read-only now. You can still read it and delete your own posts.',
    unavailable: 'Something went wrong. Please try again in a moment.',
  };
  MESSAGES.code_wait = 'Please wait a minute before asking for another code.';
  MESSAGES.bad_code = 'That code is wrong or has expired. Go back and ask for a new one.';
  const message = (code) => MESSAGES[code] || MESSAGES.unavailable;

  // ---------------------------------------------------------------------------
  // Building the page. Text is always text: h() never parses HTML, and user
  // data never goes into an attribute that could run or load anything.
  // ---------------------------------------------------------------------------

  const PROPS = new Set(['value', 'checked', 'disabled', 'hidden', 'required']);

  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const [name, value] of Object.entries(props || {})) {
      if (value == null || value === false) continue;
      if (name === 'class') el.className = value;
      else if (name === 'on') for (const [event, fn] of Object.entries(value)) el.addEventListener(event, fn);
      else if (/^on/i.test(name)) throw new Error('inline handlers are not allowed');
      else if (PROPS.has(name)) el[name] = value;
      else el.setAttribute(name, value === true ? '' : String(value));
    }
    for (const kid of kids.flat()) {
      if (kid == null || kid === false) continue;
      el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }

  const DATE = new Intl.DateTimeFormat('en-GB', {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
  });
  const when = (iso) => (iso ? DATE.format(new Date(iso)) : '');
  const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

  function show(...nodes) {
    app.replaceChildren(...nodes.flat().filter(Boolean));
    const heading = app.querySelector('h1');
    if (heading) { heading.setAttribute('tabindex', '-1'); heading.focus({ preventScroll: true }); }
  }

  function statusLine() { return h('p', { class: 'status', role: 'status' }); }
  function say(el, text, isError) { el.textContent = text || ''; el.classList.toggle('error', !!isError); }

  // Runs an action with its button disabled; shows the forum's own message on
  // failure. Returns true when the action succeeded.
  async function busy(button, status, action) {
    button.disabled = true;
    say(status, '');
    try { await action(); return true; }
    catch (error) {
      if (error && error.code === 'not_signed_in') { route(); return false; }
      say(status, message(error && error.code), true);
      return false;
    }
    finally { button.disabled = false; }
  }

  // ---------------------------------------------------------------------------
  // The session and the two kinds of request
  // ---------------------------------------------------------------------------

  const storage = {
    load() { try { return JSON.parse(localStorage.getItem(STORE) || 'null'); } catch { return null; } },
    save(value) { try { localStorage.setItem(STORE, JSON.stringify(value)); } catch { /* memory only */ } },
    clear() { try { localStorage.removeItem(STORE); } catch { /* nothing kept */ } },
  };
  let session = storage.load();

  class ForumError extends Error {
    constructor(code) { super(code); this.code = code; }
  }

  function request(path, body, token) {
    const headers = { apikey: KEY, 'content-type': 'application/json' };
    if (token) headers.authorization = 'Bearer ' + token;
    return fetch(BASE + path, {
      method: 'POST', headers, body: JSON.stringify(body || {}),
      credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'no-store',
    });
  }

  async function auth(path, body, token) {
    let response;
    try { response = await request('/auth/v1/' + path, body, token); }
    catch { return { ok: false, status: 0, data: {} }; }
    let data = {};
    try { data = await response.json(); } catch { /* empty body */ }
    return { ok: response.ok, status: response.status, data: data || {} };
  }

  function keep(data) {
    session = {
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      expires_at: Date.now() + (Number(data.expires_in) || 3600) * 1000,
    };
    storage.save(session);
  }

  function forget() { session = null; storage.clear(); }

  let refreshing = null;
  function refresh() {
    if (!refreshing) {
      refreshing = (async () => {
        // Another tab may already have rotated the refresh token.
        const stored = storage.load();
        if (stored && session && stored.refresh_token !== session.refresh_token) {
          session = stored;
          if (Date.now() < session.expires_at - 60000) return true;
        }
        if (!session || !session.refresh_token) return false;
        const result = await auth('token?grant_type=refresh_token', { refresh_token: session.refresh_token });
        if (result.ok && result.data.access_token) { keep(result.data); return true; }
        if (result.status >= 400 && result.status < 500) forget();
        return false;
      })().finally(() => { refreshing = null; });
    }
    return refreshing;
  }

  async function rpc(name, args) {
    if (!session) throw new ForumError('not_signed_in');
    if (Date.now() > session.expires_at - 60000) await refresh();
    if (!session) throw new ForumError('not_signed_in');
    const call = () => request('/rest/v1/rpc/' + name, args, session.access_token);
    let response;
    try {
      response = await call();
      if (response.status === 401 && await refresh()) response = await call();
    } catch { throw new ForumError('unavailable'); }
    let data = null;
    try { const text = await response.text(); data = text ? JSON.parse(text) : null; } catch { data = null; }
    if (response.ok) return data;
    if (response.status === 401) { forget(); throw new ForumError('not_signed_in'); }
    const match = /^forum:([a-z_]+)$/.exec((data && data.message) || '');
    throw new ForumError(match ? match[1] : 'unavailable');
  }

  async function signOut() {
    const token = session && session.access_token;
    forget();
    if (token) await auth('logout?scope=local', {}, token);
    location.hash = '#/';
    route();
  }

  window.addEventListener('storage', (event) => {
    if (event.key === STORE) { session = storage.load(); route(); }
  });

  // ---------------------------------------------------------------------------
  // Routing: #/  #/c/<slug>  #/c/<slug>/new  #/t/<id>  #/mod  #/rules
  // ---------------------------------------------------------------------------

  let me = null;
  let seq = 0;
  const current = (n) => n === seq;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const SLUG = /^[a-z0-9-]{1,40}$/;

  async function route() {
    const n = ++seq;
    const parts = location.hash.replace(/^#\/?/, '').split('/').filter(Boolean);
    if (parts[0] === 'rules') return showRules();
    if (!BASE || !KEY) { bar.hidden = true; return showOff(); }
    if (!session) { bar.hidden = true; return showSignIn(); }
    try { me = await rpc('forum_me'); }
    catch (error) {
      if (!current(n)) return;
      if (error.code === 'not_signed_in') { bar.hidden = true; return showSignIn(); }
      return showProblem(error.code);
    }
    if (!current(n)) return;
    renderBar();
    if (me.state === 'invited') return showJoin();
    if (me.state === 'not_invited') return showNotInvited();
    if (me.state === 'suspended') return showSuspended();
    if (parts.length === 0) return showHome(n);
    if (parts[0] === 'c' && SLUG.test(parts[1] || '') && parts[2] === 'new' && parts.length === 3) return showNewThread(n, parts[1]);
    if (parts[0] === 'c' && SLUG.test(parts[1] || '') && parts.length === 2) return showCategory(n, parts[1]);
    if (parts[0] === 't' && UUID.test(parts[1] || '') && parts.length === 2) return showThread(n, parts[1]);
    if (parts[0] === 'mod' && parts.length === 1 && me.moderator) return showModeration(n);
    return showProblem('not_found');
  }
  window.addEventListener('hashchange', route);

  function renderBar() {
    const signedIn = me && (me.state === 'member' || me.state === 'suspended' || me.state === 'invited' || me.state === 'not_invited');
    bar.hidden = !signedIn;
    if (!signedIn) return;
    const out = h('button', { type: 'button', class: 'link', on: { click: signOut } }, 'Sign out');
    bar.replaceChildren(...[
      h('span', { class: 'who' },
        me.display_name ? ['Signed in as ', h('strong', {}, me.display_name)] : 'Signed in',
        me.moderator ? h('span', { class: 'tag' }, 'Rebornly team') : null),
      me.state === 'member' ? h('a', { href: '#/' }, 'Forum') : null,
      me.state === 'member' && me.moderator ? h('a', { href: '#/mod' }, 'Moderation') : null,
      h('a', { href: '#/rules' }, 'Rules'),
      out].filter(Boolean));
  }

  // ---------------------------------------------------------------------------
  // Views before joining
  // ---------------------------------------------------------------------------

  function showOff() {
    show(h('h1', {}, 'Beta forum'),
      h('p', {}, 'The Rebornly beta forum is not open yet. It is for people invited to the beta, and it will open here.'),
      h('p', {}, h('a', { href: '/' }, 'Back to the start page')));
  }

  function showRules() {
    show(h('h1', {}, 'Forum rules'),
      h('p', { class: 'muted' }, 'Version ' + RULES_VERSION),
      h('ol', { class: 'rules' }, RULES.map((rule) => h('li', {}, rule))),
      h('p', {}, h('a', { href: '#/' }, 'Back to the forum')));
  }

  function showSignIn() {
    const status = statusLine();
    const email = h('input', { id: 'email', type: 'email', autocomplete: 'email', maxlength: '254', required: true });
    const send = h('button', { class: 'button', type: 'submit' }, 'Email me a code');
    const form = h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
      event.preventDefault();
      const address = email.value.trim().toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(address)) return say(status, message('invalid_email'), true);
      await busy(send, status, async () => {
        const result = await auth('otp', { email: address, create_user: true });
        // An address without an invitation is refused by the server; the page
        // answers the same either way, so it does not reveal who is invited.
        if (result.ok || result.status === 403) return showCode(address);
        if (result.status === 429) throw new ForumError('code_wait');
        throw new ForumError('unavailable');
      });
    } } },
      h('label', { for: 'email' }, 'Email address'),
      email,
      h('div', { class: 'buttons' }, send),
      status);
    show(h('h1', {}, 'Beta forum'),
      h('p', {}, 'This forum is for people invited to the Rebornly beta. Sign in with the email address your ' +
        'invitation was sent to. We email you a six-digit code; there is no password.'),
      form,
      h('p', { class: 'muted' }, 'Signing in keeps you signed in on this device until you sign out. ',
        h('a', { href: '/cookies/' }, 'Cookie policy'), ' · ', h('a', { href: '/privacy/' }, 'Privacy policy')));
  }

  function showCode(address) {
    const status = statusLine();
    const code = h('input', { id: 'code', class: 'code', type: 'text', inputmode: 'numeric',
      autocomplete: 'one-time-code', maxlength: '10', required: true });
    const go = h('button', { class: 'button', type: 'submit' }, 'Sign in');
    const form = h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
      event.preventDefault();
      const token = code.value.replace(/\s+/g, '');
      if (!/^[0-9]{6,10}$/.test(token)) return say(status, 'Please type the code from the email.', true);
      await busy(go, status, async () => {
        const result = await auth('verify', { type: 'email', email: address, token });
        if (result.ok && result.data.access_token) {
          keep(result.data);
          location.hash = '#/';
          return route();
        }
        if (result.status === 429) throw new ForumError('code_wait');
        throw new ForumError('bad_code');
      });
    } } },
      h('label', { for: 'code' }, 'Code'),
      code,
      h('div', { class: 'buttons' }, go,
        h('button', { type: 'button', class: 'link', on: { click: showSignIn } }, 'Use another address')),
      status);
    show(h('h1', {}, 'Check your email'),
      h('p', {}, 'If ', h('strong', {}, address), ' has been invited, a code is on its way to it. ' +
        'It works for 10 minutes. Look in your spam folder too.'),
      form);
  }

  function showJoin() {
    const status = statusLine();
    const name = h('input', { id: 'name', type: 'text', maxlength: '30', autocomplete: 'nickname', required: true });
    const adult = h('input', { id: 'adult', type: 'checkbox' });
    const rules = h('input', { id: 'accept', type: 'checkbox' });
    const join = h('button', { class: 'button', type: 'submit' }, 'Join the forum');
    const form = h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
      event.preventDefault();
      if (!adult.checked) return say(status, message('adult_required'), true);
      if (!rules.checked) return say(status, 'Please accept the forum rules to join.', true);
      await busy(join, status, async () => {
        me = await rpc('forum_join', { p_display_name: name.value, p_adult_confirmed: true, p_rules_version: RULES_VERSION });
        location.hash = '#/';
        return route();
      });
    } } },
      h('label', { for: 'name' }, 'Your name in the forum'),
      name,
      h('p', { class: 'hint' }, 'Other members see this name. They never see your email address.'),
      h('h2', {}, 'Forum rules'),
      h('ol', { class: 'rules' }, RULES.map((rule) => h('li', {}, rule))),
      h('label', { class: 'check', for: 'adult' }, adult, h('span', {}, 'I am 18 or older.')),
      h('label', { class: 'check', for: 'accept' }, rules,
        h('span', {}, 'I accept the forum rules and the ', h('a', { href: '/terms/' }, 'Terms'),
          '. The ', h('a', { href: '/privacy/' }, 'Privacy policy'), ' says what is stored and why.')),
      h('div', { class: 'buttons' }, join),
      status);
    show(h('h1', {}, 'Welcome to the beta forum'),
      h('p', {}, 'Choose the name other members will see, and read the rules before you join.'),
      form);
  }

  function showNotInvited() {
    show(h('h1', {}, 'Not invited'),
      h('p', {}, 'This email address has not been invited to the Rebornly beta forum, or its invitation was withdrawn.'),
      h('p', {}, 'If you think this is a mistake, email ', SUPPORT, '.'),
      h('div', { class: 'buttons' }, h('button', { class: 'button secondary', type: 'button', on: { click: signOut } }, 'Sign out')));
  }

  function showSuspended() {
    show(h('h1', {}, 'Your forum account is suspended'),
      h('p', {}, 'A moderator suspended your account for this reason:'),
      h('p', { class: 'panel' }, me.suspended_reason || ''),
      h('p', {}, 'If you think this is a mistake, email ', SUPPORT, '.'),
      h('div', { class: 'buttons' }, h('button', { class: 'button secondary', type: 'button', on: { click: signOut } }, 'Sign out')));
  }

  function showProblem(code) {
    show(h('h1', {}, code === 'not_found' ? 'Not found' : 'Something went wrong'),
      h('p', {}, message(code)),
      h('p', {}, h('a', { href: '#/' }, 'Back to the forum')));
  }

  // ---------------------------------------------------------------------------
  // The forum
  // ---------------------------------------------------------------------------

  async function load(n, name, args) {
    try { return await rpc(name, args); }
    catch (error) {
      if (!current(n)) return null;
      if (error.code === 'not_signed_in' || error.code === 'suspended' || error.code === 'not_member') { route(); return null; }
      showProblem(error.code);
      return null;
    }
  }

  const writable = () => !me.read_only || me.moderator;
  const readOnlyNote = () => (me.read_only
    ? h('p', { class: 'panel' }, 'The beta is over and the forum is read-only. It will be deleted soon, ' +
        'so copy anything you want to keep. You can still delete your own posts.')
    : null);

  async function showHome(n) {
    const categories = await load(n, 'forum_categories');
    if (!categories || !current(n)) return;
    show(h('h1', {}, 'Beta forum'),
      h('p', { class: 'muted' }, 'For people invited to the Rebornly beta. Only members can read it.'),
      readOnlyNote(),
      h('ul', { class: 'list' }, categories.map((c) => h('li', {},
        h('a', { class: 'row', href: '#/c/' + c.slug },
          h('span', { class: 'title' }, c.title, c.team_only ? h('span', { class: 'tag' }, 'Team') : null),
          h('span', { class: 'desc' }, c.description),
          h('span', { class: 'meta' }, plural(c.thread_count, 'thread', 'threads'),
            c.last_post_at ? ' · last post ' + when(c.last_post_at) : ''))))));
  }

  function threadRow(t) {
    return h('li', {}, h('a', { class: 'row', href: '#/t/' + t.id },
      h('span', { class: 'title' }, t.title || 'Deleted by its author',
        t.pinned ? h('span', { class: 'tag' }, 'Pinned') : null,
        t.locked ? h('span', { class: 'tag' }, 'Locked') : null,
        t.hidden ? h('span', { class: 'tag' }, 'Hidden') : null),
      h('span', { class: 'meta' },
        'by ', t.author.name || 'a former member',
        ' · ', plural(t.replies, 'reply', 'replies'),
        ' · last post ', when(t.last_post_at))));
  }

  async function showCategory(n, slug) {
    const page = await load(n, 'forum_threads', { p_category: slug, p_limit: 30, p_offset: 0 });
    if (!page || !current(n)) return;
    const c = page.category;
    const list = h('ul', { class: 'list' }, page.threads.map(threadRow));
    let shown = page.threads.length;
    const status = statusLine();
    const more = h('button', { class: 'button secondary', type: 'button', hidden: shown >= page.total, on: { click: () =>
      busy(more, status, async () => {
        const next = await rpc('forum_threads', { p_category: slug, p_limit: 30, p_offset: shown });
        next.threads.forEach((t) => list.append(threadRow(t)));
        shown += next.threads.length;
        more.hidden = shown >= next.total || next.threads.length === 0;
      }) } }, 'Show older threads');
    const canStart = (!c.team_only || me.moderator) && writable();
    show(h('p', { class: 'crumbs' }, h('a', { href: '#/' }, 'Forum')),
      h('h1', {}, c.title),
      h('p', {}, c.description),
      readOnlyNote(),
      canStart ? h('div', { class: 'buttons' }, h('a', { class: 'button', href: '#/c/' + c.slug + '/new' }, 'Start a thread')) : null,
      h('h2', {}, plural(page.total, 'thread', 'threads')),
      page.total ? list : h('p', { class: 'muted' }, 'No threads yet.'),
      h('div', { class: 'buttons' }, more),
      status);
  }

  async function showNewThread(n, slug) {
    const page = await load(n, 'forum_threads', { p_category: slug, p_limit: 1, p_offset: 0 });
    if (!page || !current(n)) return;
    const c = page.category;
    const status = statusLine();
    const title = h('input', { id: 'title', type: 'text', maxlength: '120', required: true });
    const body = h('textarea', { id: 'body', maxlength: '10000', required: true });
    const post = h('button', { class: 'button', type: 'submit' }, 'Post thread');
    const form = h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
      event.preventDefault();
      await busy(post, status, async () => {
        const id = await rpc('forum_create_thread', { p_category: c.slug, p_title: title.value, p_body: body.value });
        location.hash = '#/t/' + id;
      });
    } } },
      h('label', { for: 'title' }, 'Title'), title,
      h('label', { for: 'body' }, 'Your post'), body,
      c.slug === 'bugs' ? h('p', { class: 'hint' }, 'Say what you did, what you expected and what happened, and which phone and app version you use.') : null,
      h('div', { class: 'buttons' }, post, h('a', { href: '#/c/' + c.slug }, 'Cancel')),
      status);
    show(h('p', { class: 'crumbs' }, h('a', { href: '#/' }, 'Forum'), ' › ', h('a', { href: '#/c/' + c.slug }, c.title)),
      h('h1', {}, 'Start a thread'),
      form);
  }

  // A small form asking for a reason, shown in place under a post.
  function reasonForm(slot, label, submitText, onSubmit) {
    const status = statusLine();
    const field = h('textarea', { maxlength: '500', rows: '3', 'aria-label': label });
    const go = h('button', { class: 'button', type: 'submit' }, submitText);
    const form = h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
      event.preventDefault();
      await busy(go, status, () => onSubmit(field.value));
    } } },
      h('label', {}, label), field,
      h('div', { class: 'buttons' }, go,
        h('button', { type: 'button', class: 'link', on: { click: () => slot.replaceChildren() } }, 'Cancel')),
      status);
    slot.replaceChildren(form);
    field.focus();
  }

  function postView(p, thread, reload) {
    const slot = h('div', {});
    const status = statusLine();
    const content = [];
    if (p.deleted) content.push(h('p', { class: 'gone' }, 'Deleted by its author.'));
    else if (p.hidden && p.body == null) content.push(h('p', { class: 'gone' }, 'Removed by a moderator.'));
    else {
      if (p.hidden) {
        content.push(h('p', { class: 'notice' }, p.mine
          ? ['A moderator hid this post: ', p.hidden_reason || '', '. Only you and the moderators can see it.']
          : ['Hidden for members: ', p.hidden_reason || '']));
      }
      content.push(h('p', { class: 'body' }, p.body));
    }
    const actions = [];
    const locked = ((thread.locked || thread.hidden) && !me.moderator) || !writable();
    if (p.mine && !p.deleted && !p.hidden && !locked) {
      actions.push(h('button', { type: 'button', class: 'link', on: { click: () => editForm(slot, p, thread, reload) } }, 'Edit'));
    }
    if (p.mine && !p.deleted) {
      actions.push(h('button', { type: 'button', class: 'link danger', on: { click: async (event) => {
        const what = p.opening ? 'Delete this thread\'s opening post and its title? Replies stay.' : 'Delete this post?';
        if (!window.confirm(what + ' This cannot be undone.')) return;
        if (await busy(event.currentTarget, status, () => rpc('forum_delete_post', { p_post_id: p.id }))) reload();
      } } }, 'Delete'));
    }
    if (!p.mine && !p.deleted && !p.hidden && !me.moderator) {
      actions.push(h('button', { type: 'button', class: 'link', on: { click: () =>
        reasonForm(slot, 'Why are you reporting this post?', 'Send report', async (reason) => {
          await rpc('forum_report_post', { p_post_id: p.id, p_reason: reason });
          slot.replaceChildren(h('p', { class: 'muted' }, 'Thank you. The moderators will look at it.'));
        }) } }, 'Report'));
    }
    if (me.moderator && !p.deleted) {
      actions.push(p.hidden
        ? h('button', { type: 'button', class: 'link', on: { click: async (event) => {
            if (await busy(event.currentTarget, status, () => rpc('forum_mod_unhide_post', { p_post_id: p.id }))) reload();
          } } }, 'Restore')
        : h('button', { type: 'button', class: 'link danger', on: { click: () =>
            reasonForm(slot, p.opening ? 'Why is this thread being hidden? Its author will see this.'
                                       : 'Why is this post being hidden? Its author will see this.',
              'Hide', async (reason) => {
                await rpc('forum_mod_hide_post', { p_post_id: p.id, p_reason: reason });
                reload();
              }) } }, p.opening ? 'Hide thread' : 'Hide'));
    }
    return h('article', { class: 'post' + (p.hidden ? ' is-hidden' : ''), id: 'post-' + p.id },
      h('header', {},
        h('span', { class: 'author' }, p.author.name || 'A former member'),
        p.author.team ? h('span', { class: 'tag' }, 'Rebornly team') : null,
        h('span', { class: 'when' }, when(p.created_at), p.edited_at && !p.deleted ? ' · edited' : '')),
      content,
      actions.length ? h('div', { class: 'actions' }, actions) : null,
      slot, status);
  }

  function editForm(slot, p, thread, reload) {
    const status = statusLine();
    const title = p.opening ? h('input', { type: 'text', maxlength: '120', value: thread.title || '', 'aria-label': 'Title' }) : null;
    const body = h('textarea', { maxlength: '10000', 'aria-label': 'Your post', value: p.body || '' });
    const save = h('button', { class: 'button', type: 'submit' }, 'Save');
    slot.replaceChildren(h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
      event.preventDefault();
      const args = { p_post_id: p.id, p_body: body.value };
      if (title) args.p_title = title.value;
      if (await busy(save, status, () => rpc('forum_edit_post', args))) reload();
    } } },
      title ? [h('label', {}, 'Title'), title] : null,
      h('label', {}, 'Your post'), body,
      h('div', { class: 'buttons' }, save,
        h('button', { type: 'button', class: 'link', on: { click: () => slot.replaceChildren() } }, 'Cancel')),
      status));
    body.focus();
  }

  async function showThread(n, id, scrollToEnd) {
    const data = await load(n, 'forum_thread', { p_thread_id: id, p_limit: 100, p_offset: 0 });
    if (!data || !current(n)) return;
    const t = data.thread;
    const reload = (end) => showThread(seq, id, end);
    const posts = h('div', {}, data.posts.map((p) => postView(p, t, reload)));
    let shown = data.posts.length;
    const status = statusLine();
    const more = h('button', { class: 'button secondary', type: 'button', hidden: shown >= data.total, on: { click: () =>
      busy(more, status, async () => {
        const next = await rpc('forum_thread', { p_thread_id: id, p_limit: 100, p_offset: shown });
        next.posts.forEach((p) => posts.append(postView(p, t, reload)));
        shown += next.posts.length;
        more.hidden = shown >= next.total || next.posts.length === 0;
      }) } }, 'Show more posts');

    const tools = [];
    if (me.moderator) {
      const setThread = (args) => async (event) => {
        if (await busy(event.currentTarget, status, () => rpc('forum_mod_set_thread', { p_thread_id: id, ...args }))) reload();
      };
      tools.push(h('div', { class: 'actions' },
        h('button', { type: 'button', class: 'link', on: { click: setThread({ p_pinned: !t.pinned }) } }, t.pinned ? 'Unpin' : 'Pin'),
        h('button', { type: 'button', class: 'link', on: { click: setThread({ p_locked: !t.locked }) } }, t.locked ? 'Unlock' : 'Lock')));
    }

    let reply = null;
    if (t.can_reply && writable()) {
      const rstatus = statusLine();
      const body = h('textarea', { id: 'reply', maxlength: '10000', required: true });
      const send = h('button', { class: 'button', type: 'submit' }, 'Post reply');
      reply = h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
        event.preventDefault();
        if (await busy(send, rstatus, () => rpc('forum_reply', { p_thread_id: id, p_body: body.value }))) reload(true);
      } } },
        h('label', { for: 'reply' }, 'Reply'), body,
        h('div', { class: 'buttons' }, send), rstatus);
    } else {
      reply = h('p', { class: 'muted' }, !writable() ? 'The forum is read-only.'
        : t.hidden ? 'This thread is hidden.' : 'This thread is locked. No new replies can be posted.');
    }

    show(h('p', { class: 'crumbs' }, h('a', { href: '#/' }, 'Forum'), ' › ', h('a', { href: '#/c/' + t.category.slug }, t.category.title)),
      h('h1', {}, t.title || 'Deleted by its author'),
      readOnlyNote(),
      h('p', { class: 'muted' },
        t.pinned ? h('span', { class: 'tag' }, 'Pinned') : null,
        t.locked ? h('span', { class: 'tag' }, 'Locked') : null,
        t.hidden ? h('span', { class: 'tag' }, 'Hidden') : null),
      t.hidden && t.hidden_reason ? h('p', { class: 'panel' }, 'A moderator hid this thread: ', t.hidden_reason,
        '. Only its author and the moderators can see it.') : null,
      tools, posts,
      h('div', { class: 'buttons' }, more), status,
      reply);
    if (scrollToEnd) reply.scrollIntoView({ block: 'center' });
  }

  // ---------------------------------------------------------------------------
  // Moderation
  // ---------------------------------------------------------------------------

  async function showModeration(n) {
    const [reports, invitations, members] = await Promise.all([
      load(n, 'forum_mod_reports', { p_include_resolved: false }),
      load(n, 'forum_mod_invitations'),
      load(n, 'forum_mod_members'),
    ]);
    if (!reports || !invitations || !members || !current(n)) return;
    const again = () => showModeration(seq);

    const reportList = reports.length ? reports.map((r) => {
      const slot = h('div', {});
      const status = statusLine();
      return h('div', { class: 'panel' },
        h('p', {}, h('a', { href: '#/t/' + r.thread_id }, r.thread_title || 'Deleted thread')),
        h('p', { class: 'body' }, r.post_deleted ? '(deleted by its author)' : r.excerpt || ''),
        h('p', { class: 'muted' }, 'Post by ', r.post_author.name || 'a former member',
          r.post_hidden ? ' · already hidden' : ''),
        h('p', {}, 'Reported by ', r.reporter.name || 'a former member', ' on ', when(r.created_at), ': ', r.reason),
        h('div', { class: 'actions' },
          !r.post_hidden && !r.post_deleted ? h('button', { type: 'button', class: 'link danger', on: { click: () =>
            reasonForm(slot, 'Why is this post being hidden? Its author will see this.', 'Hide', async (reason) => {
              await rpc('forum_mod_hide_post', { p_post_id: r.post_id, p_reason: reason });
              await rpc('forum_mod_resolve_report', { p_report_id: r.id, p_resolution: 'Hidden: ' + reason });
              again();
            }) } }, 'Hide post and resolve') : null,
          h('button', { type: 'button', class: 'link', on: { click: () =>
            reasonForm(slot, 'What did you decide?', 'Resolve', async (note) => {
              await rpc('forum_mod_resolve_report', { p_report_id: r.id, p_resolution: note });
              again();
            }) } }, 'Resolve')),
        slot, status);
    }) : [h('p', { class: 'muted' }, 'No open reports.')];

    const istatus = statusLine();
    const email = h('input', { id: 'invite', type: 'email', maxlength: '254', autocomplete: 'off' });
    const invite = h('button', { class: 'button', type: 'submit' }, 'Invite');
    const inviteForm = h('form', { class: 'form', novalidate: true, on: { submit: async (event) => {
      event.preventDefault();
      if (await busy(invite, istatus, () => rpc('forum_mod_invite', { p_email: email.value }))) again();
    } } },
      h('label', { for: 'invite' }, 'Invite an email address'), email,
      h('p', { class: 'hint' }, 'This only lets the address sign in. Write to the person yourself and send them to rebornlyapp.com/forum/.'),
      h('div', { class: 'buttons' }, invite), istatus);

    const inviteRows = invitations.map((i) => {
      const status = statusLine();
      return h('tr', {},
        h('td', {}, i.email),
        h('td', {}, i.member ? 'Joined as ' + i.member : i.revoked ? 'Withdrawn' : 'Invited ' + when(i.invited_at)),
        h('td', {}, i.revoked ? null : h('button', { type: 'button', class: 'link danger', on: { click: async (event) => {
          if (!window.confirm('Withdraw the invitation for ' + i.email + '? A member who has joined keeps access until suspended.')) return;
          if (await busy(event.currentTarget, status, () => rpc('forum_mod_revoke_invite', { p_email: i.email }))) again();
        } } }, 'Withdraw'), status));
    });

    const memberRows = members.map((m) => {
      const slot = h('div', {});
      const status = statusLine();
      let action = null;
      if (!m.moderator && m.status === 'active') {
        action = h('button', { type: 'button', class: 'link danger', on: { click: () =>
          reasonForm(slot, 'Why is ' + m.display_name + ' being suspended? They will see this.', 'Suspend', async (reason) => {
            await rpc('forum_mod_suspend', { p_user_id: m.user_id, p_reason: reason });
            again();
          }) } }, 'Suspend');
      } else if (m.status === 'suspended') {
        action = h('button', { type: 'button', class: 'link', on: { click: async (event) => {
          if (await busy(event.currentTarget, status, () => rpc('forum_mod_unsuspend', { p_user_id: m.user_id }))) again();
        } } }, 'Lift suspension');
      }
      return h('tr', {},
        h('td', {}, m.display_name, m.moderator ? h('span', { class: 'tag' }, 'Team') : null),
        h('td', {}, m.email),
        h('td', {}, m.status === 'suspended' ? 'Suspended: ' + (m.suspended_reason || '') : plural(m.posts, 'post', 'posts')),
        h('td', {}, action, slot, status));
    });

    show(h('p', { class: 'crumbs' }, h('a', { href: '#/' }, 'Forum')),
      h('h1', {}, 'Moderation'),
      h('h2', {}, 'Open reports'), reportList,
      h('h2', {}, 'Invitations'), inviteForm,
      invitations.length ? h('table', { class: 'table' },
        h('thead', {}, h('tr', {}, h('th', {}, 'Email'), h('th', {}, 'Status'), h('th', {}, ''))),
        h('tbody', {}, inviteRows)) : null,
      h('h2', {}, 'Members'),
      h('table', { class: 'table' },
        h('thead', {}, h('tr', {}, h('th', {}, 'Name'), h('th', {}, 'Email'), h('th', {}, 'Status'), h('th', {}, ''))),
        h('tbody', {}, memberRows)));
  }

  if (BASE && KEY) app.replaceChildren(h('p', { class: 'muted' }, 'Loading…'));
  route();
})();
