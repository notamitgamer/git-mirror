/* git-mirror front-end: instant page swaps, aggressive prefetch, search, small UI helpers. ~no deps. */
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const ORIGIN = location.origin;
  const BASE = document.body.dataset.base || '';   // '' at a domain root, '/repo' on project Pages

  /* ───── page cache + prefetch ───── */
  const cache = new Map();                 // key -> Promise<string|null>
  const MAX_CACHE = 150;
  const key = (u) => u.pathname + u.search;
  function fetchPage(k) {
    if (cache.has(k)) return cache.get(k);
    const p = fetch(k, { credentials: 'same-origin' })
      .then((r) => (r.ok && (r.headers.get('content-type') || '').includes('text/html') ? r.text() : null))
      .catch(() => null);
    p.then((t) => { if (t === null) cache.delete(k); });
    cache.set(k, p);
    if (cache.size > MAX_CACHE) cache.delete(cache.keys().next().value);
    return p;
  }
  const queue = [];
  let active = 0;
  function pump() {
    while (active < 4 && queue.length) {
      const k = queue.shift();
      if (cache.has(k)) continue;
      active++;
      fetchPage(k).finally(() => { active--; pump(); });
    }
  }
  function warm(k, front) {
    if (cache.has(k) || queue.includes(k)) return;
    front ? queue.unshift(k) : queue.push(k);
    pump();
  }
  function pageUrl(a) {
    if (!a || !a.href || a.target || a.hasAttribute('download') || a.hasAttribute('data-nopjax')) return null;
    let u;
    try { u = new URL(a.href, location.href); } catch { return null; }
    if (u.origin !== ORIGIN || !u.pathname.startsWith(BASE + '/') || !u.pathname.endsWith('/')) return null;
    if (u.pathname === location.pathname && u.search === location.search) return null;   // same page (#hash)
    return u;
  }
  const io = 'IntersectionObserver' in window ? new IntersectionObserver((es) => {
    for (const e of es) if (e.isIntersecting) { io.unobserve(e.target); const u = pageUrl(e.target); if (u) warm(key(u)); }
  }, { rootMargin: '1400px 0px' }) : null;
  function observeLinks() {
    const links = () => $$('main a[href], .nav a[href]');
    const run = () => links().forEach((a) => (io ? io.observe(a) : (pageUrl(a) && warm(key(pageUrl(a))))));
    ('requestIdleCallback' in window) ? requestIdleCallback(run, { timeout: 600 }) : setTimeout(run, 50);
    // then sweep everything else on the page (capped), so the whole neighbourhood is already in memory
    setTimeout(() => { let n = 0; for (const a of links()) { const u = pageUrl(a); if (u && n++ < 120) warm(key(u)); } }, 1200);
  }
  // hover / touch / focus => jump the queue
  const hot = (e) => { const a = e.target.closest && e.target.closest('a'); const u = a && pageUrl(a); if (u) warm(key(u), true); };
  document.addEventListener('pointerover', hot, { passive: true });
  document.addEventListener('touchstart', hot, { passive: true });
  document.addEventListener('focusin', hot);

  /* ───── instant navigation (pjax) ───── */
  history.scrollRestoration = 'manual';
  let navId = 0;
  async function go(url, mode) {              // mode: 'push' | 'pop'
    const id = ++navId, k = key(url);
    const timer = setTimeout(() => document.documentElement.classList.add('loading'), 140);
    const text = await fetchPage(k);
    clearTimeout(timer);
    document.documentElement.classList.remove('loading');
    if (id !== navId) return;
    if (text == null) { location.href = url.href; return; }
    const doc = new DOMParser().parseFromString(text, 'text/html');
    const next = $('#main', doc);
    if (!next) { location.href = url.href; return; }
    const swap = () => {
      if (mode === 'push') history.replaceState({ y: scrollY }, '');
      document.title = doc.title;
      $('#main').replaceWith(next);
      if (mode === 'push') history.pushState({ y: 0 }, '', url.href);
      closeResults(); $$('details.clone[open]').forEach((d) => d.removeAttribute('open'));
      const y = mode === 'pop' ? (history.state && history.state.y) || 0 : 0;
      scrollTo(0, y);
      init();
      if (url.hash) { const t = document.getElementById(decodeURIComponent(url.hash.slice(1))); if (t) t.scrollIntoView(); }
    };
    document.startViewTransition ? document.startViewTransition(swap) : swap();
  }
  document.addEventListener('click', (e) => {
    if (e.defaultPrevented || e.button || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest && e.target.closest('a');
    const u = pageUrl(a);
    if (!u) return;
    e.preventDefault();
    go(u, 'push');
  });
  addEventListener('popstate', () => {
    const u = new URL(location.href);
    if (key(u) === (window.__cur || '')) { applyHash(); return; }
    go(u, 'pop');
  });

  /* ───── relative time ───── */
  const rtf = 'Intl' in window && Intl.RelativeTimeFormat ? new Intl.RelativeTimeFormat('en', { numeric: 'auto' }) : null;
  const UNITS = [['year', 31536e6], ['month', 2592e6], ['week', 6048e5], ['day', 864e5], ['hour', 36e5], ['minute', 6e4]];
  function times(root) {
    $$('time.rt', root).forEach((t) => {
      const d = new Date(t.getAttribute('datetime'));
      if (isNaN(d)) return;
      t.title = d.toLocaleString();
      if (!rtf) return;
      const diff = d - Date.now();
      for (const [u, ms] of UNITS) if (Math.abs(diff) >= ms) { t.textContent = rtf.format(Math.round(diff / ms), u); return; }
      t.textContent = 'just now';
    });
  }

  /* ───── clipboard / share / popovers ───── */
  async function copy(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch {
      const ta = document.createElement('textarea'); ta.value = text; ta.style.cssText = 'position:fixed;opacity:0';
      document.body.appendChild(ta); ta.select(); let ok = false; try { ok = document.execCommand('copy'); } catch {} ta.remove(); return ok;
    }
  }
  document.addEventListener('click', async (e) => {
    const c = e.target.closest('[data-copy]');
    if (c) { if (await copy(c.dataset.copy)) { c.classList.add('done'); setTimeout(() => c.classList.remove('done'), 1500); } return; }
    if (e.target.closest('#share')) {
      const data = { title: document.title, url: location.href };
      if (navigator.share) { try { await navigator.share(data); } catch {} } else { await copy(location.href); }
      return;
    }
    const v = e.target.closest('[data-view]');
    if (v) { const b = v.closest('.blob'); b.classList.toggle('md-on', v.dataset.view === 'md'); $$('[data-view]', b).forEach((x) => x.classList.toggle('on', x === v)); return; }
    const g = e.target.closest('[data-goto]');
    if (g) { openSearch(g.dataset.goto); return; }
    $$('details.clone[open]').forEach((d) => { if (!d.contains(e.target)) d.removeAttribute('open'); });
    if (!e.target.closest('.search')) closeResults();
  });

  /* ───── line highlighting (#L10 or #L10-L20) ───── */
  function applyHash() {
    $$('.hl').forEach((n) => n.classList.remove('hl'));
    const m = /^#L(\d+)(?:-L?(\d+))?$/.exec(location.hash);
    if (!m) return;
    const a = +m[1], b = Math.min(+(m[2] || m[1]), a + 5000);
    for (let i = a; i <= Math.max(a, b); i++) {
      const n = document.getElementById('L' + i), c = document.getElementById('C' + i);
      if (n) n.classList.add('hl'); if (c) c.classList.add('hl');
    }
    const t = document.getElementById('L' + a);
    if (t) t.scrollIntoView({ block: 'center' });
  }
  addEventListener('hashchange', applyHash);

  /* ───── home: filter / sort ───── */
  function homeList() {
    const list = $('#rl'); if (!list) return;
    const f = $('#rf'), s = $('#rs'), empty = $('#rempty');
    const rows = $$('.rrow', list);
    const run = () => {
      const q = f.value.trim().toLowerCase();
      const by = s.value;
      rows.sort((a, b) => by === 'n' ? a.dataset.n.localeCompare(b.dataset.n) : (b.dataset[by] - a.dataset[by]) || a.dataset.n.localeCompare(b.dataset.n));
      let shown = 0;
      rows.forEach((r) => {
        const hit = !q || (r.dataset.n + ' ' + r.dataset.d + ' ' + r.dataset.l).includes(q);
        r.hidden = !hit; if (hit) shown++;
        list.appendChild(r);
      });
      empty.hidden = shown > 0;
    };
    f.oninput = run; s.onchange = run;
  }

  /* ───── global search (repos + files) ───── */
  const input = $('#q'), box = $('#results');
  let index = null, loading = null, sel = -1, hits = [];
  function loadIndex() {
    if (index) return Promise.resolve(index);
    return loading || (loading = fetch(BASE + '/search.json').then((r) => r.json()).then((d) => (index = d)).catch(() => (index = { r: [] })));
  }
  function closeResults() { box.hidden = true; sel = -1; }
  function openSearch(prefill) { input.focus(); if (prefill != null) { input.value = prefill; search(); } }
  const enc = (p) => p.split('/').map(encodeURIComponent).join('/');
  async function search() {
    const raw = input.value.trim().toLowerCase();
    if (!raw) { closeResults(); return; }
    await loadIndex();
    const toks = raw.split(/\s+/);
    const out = [];
    for (const r of index.r) {
      const hay = (r.n + ' ' + r.d).toLowerCase();
      if (toks.every((t) => hay.includes(t))) out.push({ t: 'r', s: r.n.toLowerCase().startsWith(toks[0]) ? 0 : 1, r });
    }
    out.sort((a, b) => a.s - b.s);
    const repos = out.slice(0, 6);
    const files = [];
    outer: for (const r of index.r) {
      for (const f of r.f) {
        const hay = (r.n + '/' + f).toLowerCase();
        if (toks.every((t) => hay.includes(t))) { files.push({ r: r.n, f, s: f.toLowerCase().split('/').pop().includes(toks[toks.length - 1]) ? 0 : 1 }); if (files.length > 400) break outer; }
      }
    }
    files.sort((a, b) => a.s - b.s || a.f.length - b.f.length);
    hits = [];
    let h = '';
    if (repos.length) { h += '<div class="rh">Repositories</div>'; for (const x of repos) { hits.push(BASE + '/' + encodeURIComponent(x.r.n) + '/'); h += `<a href="${hits[hits.length - 1]}"><b>${esc(x.r.n)}</b><small>${esc(x.r.d)}</small></a>`; } }
    const fs = files.slice(0, 30);
    if (fs.length) { h += '<div class="rh">Files</div>'; for (const x of fs) { const u = BASE + '/' + encodeURIComponent(x.r) + '/blob/' + enc(x.f) + '/'; hits.push(u); h += `<a href="${u}"><b>${esc(x.f)}</b><small>${esc(x.r)}</small></a>`; } }
    box.innerHTML = h || '<div class="none">No matches.</div>';
    box.hidden = false; sel = -1;
  }
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  function mark() { $$('a', box).forEach((a, i) => a.setAttribute('aria-selected', i === sel ? 'true' : 'false')); const a = $$('a', box)[sel]; if (a) a.scrollIntoView({ block: 'nearest' }); }
  input.addEventListener('input', search);
  input.addEventListener('focus', () => { loadIndex(); if (input.value.trim()) search(); });
  input.addEventListener('keydown', (e) => {
    const n = $$('a', box).length;
    if (e.key === 'ArrowDown') { e.preventDefault(); sel = (sel + 1) % Math.max(n, 1); mark(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); sel = (sel - 1 + n) % Math.max(n, 1); mark(); }
    else if (e.key === 'Enter') { const a = $$('a', box)[Math.max(sel, 0)]; if (a) { a.click(); input.blur(); } }
    else if (e.key === 'Escape') { closeResults(); input.blur(); }
  });
  document.addEventListener('keydown', (e) => {
    if (e.target.matches('input,textarea,select') || e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === '/') { e.preventDefault(); openSearch(); }
    else if (e.key === 't') { const g = $('[data-goto]'); if (g) { e.preventDefault(); openSearch(g.dataset.goto); } }
  });

  /* ───── installable app (PWA) ───── */
  if ('serviceWorker' in navigator) navigator.serviceWorker.register(BASE + '/sw.js').catch(() => {});
  const install = $('#install');
  let prompt_ = null;
  addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); prompt_ = e; install.hidden = false; });
  addEventListener('appinstalled', () => { prompt_ = null; install.hidden = true; });
  install.addEventListener('click', async () => {
    if (!prompt_) return;
    const p = prompt_; prompt_ = null; install.hidden = true;
    await p.prompt();
  });

  /* ───── init per page ───── */
  function init() {
    window.__cur = location.pathname + location.search;
    times(document); homeList(); applyHash(); observeLinks();
  }
  history.replaceState({ y: 0 }, '');
  init();
})();
