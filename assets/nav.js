(() => {
  const copyText = async (text) => {
    try { await navigator.clipboard.writeText(text); return true; }
    catch {
      const t = document.createElement('textarea');
      t.value = text; t.style.position = 'fixed'; t.style.opacity = '0';
      document.body.appendChild(t); t.select();
      let ok = false;
      try { ok = document.execCommand('copy'); } catch {}
      t.remove();
      return ok;
    }
  };

  // Copy-to-clipboard for clone commands
  document.addEventListener('click', async (e) => {
    const btn = e.target.closest('button.copy');
    if (!btn) return;
    await copyText(btn.dataset.copy);
    btn.classList.add('done');
    setTimeout(() => btn.classList.remove('done'), 1500);
  });

  // Share: native share sheet (mobile + supporting desktops), fallback = copy the page link
  document.addEventListener('click', async (e) => {
    const btn = e.target.closest('button.share');
    if (!btn) return;
    const data = { title: document.title, url: location.href };
    const label = btn.querySelector('span');
    const flash = (msg) => {
      const old = label.textContent;
      label.textContent = msg; btn.classList.add('done');
      setTimeout(() => { label.textContent = old; btn.classList.remove('done'); }, 1600);
    };
    if (navigator.share && (!navigator.canShare || navigator.canShare(data))) {
      try { await navigator.share(data); return; }
      catch (err) { if (err && err.name === 'AbortError') return; /* else fall through to copy */ }
    }
    flash((await copyText(data.url)) ? 'Link copied' : 'Copy failed');
  });

  // ---------- Search / sort ----------
  const $ = (id) => document.getElementById(id);
  const ext = (p) => { const f = p.split('/').pop(); const i = f.lastIndexOf('.'); return i > 0 ? f.slice(i + 1).toLowerCase() : ''; };
  const base = (p) => p.split('/').pop().toLowerCase();
  const esc = (t) => t.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const href = (repo, path) => '/' + encodeURIComponent(repo) + '/file/' + path.split('/').map(encodeURIComponent).join('/') + '.html';

  // score a path against query tokens; -1 = no match
  const score = (path, toks) => {
    const lp = path.toLowerCase(), name = base(path);
    let s = 0;
    for (const t of toks) {
      if (name === t) s += 100;
      else if (name.startsWith(t)) s += 60;
      else if (name.includes(t)) s += 40;
      else if (lp.includes(t)) s += 10;
      else return -1;
    }
    return s - Math.min(path.length / 100, 5);
  };
  const sortHits = (hits, mode) => {
    const by = {
      rel: (x, y) => y.s - x.s || x.path.localeCompare(y.path),
      az: (x, y) => base(x.path).localeCompare(base(y.path)) || x.repo.localeCompare(y.repo),
      za: (x, y) => base(y.path).localeCompare(base(x.path)) || x.repo.localeCompare(y.repo),
      ext: (x, y) => ext(x.path).localeCompare(ext(y.path)) || base(x.path).localeCompare(base(y.path)),
    };
    return hits.sort(by[mode] || by.rel);
  };

  let indexPromise = null;
  const loadIndex = (repo) => {
    // repo page: just this repo's list; homepage: global index
    if (repo) {
      return fetch('/' + encodeURIComponent(repo) + '/search.json').then((r) => r.json()).then((l) => ({ [repo]: l }));
    }
    return indexPromise || (indexPromise = fetch('/search-index.json').then((r) => r.json()));
  };

  const results = $('file-results');
  const MAX = 100;
  let data = null, lastToks = [], repoFilter = null;

  const renderFiles = () => {
    if (!results) return;
    const toks = lastToks;
    if (!toks.length || !data) { results.hidden = true; return; }
    const hits = [];
    for (const repo in data) {
      if (repoFilter && repo !== repoFilter) continue;
      for (const path of data[repo]) {
        const sc = score(repo === repoFilter ? path : path, toks);
        if (sc >= 0) hits.push({ repo, path, s: sc });
      }
    }
    sortHits(hits, $('fsort').value);
    const shown = hits.slice(0, MAX);
    results.querySelector('ul').innerHTML = shown.map((h) => {
      const dir = h.path.includes('/') ? h.path.slice(0, h.path.lastIndexOf('/') + 1) : '';
      const file = h.path.split('/').pop();
      return '<li><a href="' + href(h.repo, h.path) + '">' +
        (repoFilter ? '' : '<span class="r-repo">' + esc(h.repo) + '</span>') +
        '<span class="r-path">' + esc(dir) + '<b>' + esc(file) + '</b></span></a></li>';
    }).join('') || '<li class="none">No files match.</li>';
    $('file-count').textContent = hits.length + (hits.length === 1 ? ' file' : ' files') +
      (hits.length > MAX ? ' (showing first ' + MAX + ')' : '');
    results.hidden = false;
  };

  const parse = (v) => v.trim().toLowerCase().split(/\s+/).filter(Boolean);

  // Homepage: filter + sort repos, and search files across all repos
  const q = $('q');
  if (q) {
    const list = $('index');
    const items = [...list.querySelectorAll('.repo')];
    const empty = $('no-results');
    const sort = $('sort');
    const cmp = {
      updated: (a, b) => b.dataset.date.localeCompare(a.dataset.date),
      oldest: (a, b) => a.dataset.date.localeCompare(b.dataset.date),
      az: (a, b) => a.dataset.name.localeCompare(b.dataset.name),
      za: (a, b) => b.dataset.name.localeCompare(a.dataset.name),
    };
    const applySort = () => { items.sort(cmp[sort.value]).forEach((li) => list.appendChild(li)); };
    const apply = () => {
      const toks = parse(q.value);
      let shown = 0;
      items.forEach((li) => {
        const text = li.textContent.toLowerCase();
        const hit = toks.every((t) => text.includes(t));
        li.hidden = !hit; if (hit) shown++;
      });
      if (empty) empty.hidden = shown > 0 || toks.length === 0 || !results.hidden;
      lastToks = toks.length && q.value.trim().length >= 2 ? toks : [];
      if (lastToks.length) {
        if (data) renderFiles();
        else loadIndex().then((d) => { data = d; renderFiles(); }).catch(() => {});
      } else renderFiles();
    };
    sort.addEventListener('change', applySort);
    $('fsort').addEventListener('change', renderFiles);
    q.addEventListener('input', apply);
    q.addEventListener('focus', () => loadIndex().then((d) => { data = d; }).catch(() => {}), { once: true });
    applySort();
  }

  // Repo page: search this repo's files
  const fq = $('fq');
  if (fq) {
    repoFilter = document.body.dataset.repo;
    const content = $('content');
    const run = () => {
      lastToks = parse(fq.value);
      if (!lastToks.length) { renderFiles(); if (content) content.hidden = false; return; }
      if (content) content.hidden = true;
      if (data) renderFiles();
      else loadIndex(repoFilter).then((d) => { data = d; renderFiles(); }).catch(() => {});
    };
    fq.addEventListener('input', run);
    $('fsort').addEventListener('change', renderFiles);
    fq.addEventListener('focus', () => loadIndex(repoFilter).then((d) => { data = d; }).catch(() => {}), { once: true });
    // press "/" to focus search
    document.addEventListener('keydown', (e) => {
      if (e.key === '/' && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) { e.preventDefault(); fq.focus(); }
    });
  }
  if (q) document.addEventListener('keydown', (e) => {
    if (e.key === '/' && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) { e.preventDefault(); q.focus(); }
  });

  // Prefetch fallback for browsers without Speculation Rules (Safari/Firefox):
  // warm same-origin links on hover/touch and when they scroll into view.
  if (!(HTMLScriptElement.supports && HTMLScriptElement.supports('speculationrules'))) {
    const done = new Set();
    const warm = (a) => {
      if (!a || a.origin !== location.origin || a.target === '_blank') return;
      const url = a.href.split('#')[0];
      if (done.has(url) || url === location.href.split('#')[0] || !/\.html$|\/$/.test(url)) return;
      done.add(url);
      const l = document.createElement('link');
      l.rel = 'prefetch'; l.href = url; l.as = 'document';
      document.head.appendChild(l);
    };
    const near = (e) => warm(e.target.closest && e.target.closest('a[href]'));
    document.addEventListener('pointerover', near, { passive: true });
    document.addEventListener('touchstart', near, { passive: true });
    if ('IntersectionObserver' in window) {
      const io = new IntersectionObserver((ents) => ents.forEach(en => {
        if (en.isIntersecting) { warm(en.target); io.unobserve(en.target); }
      }), { rootMargin: '200px' });
      document.querySelectorAll('a.repo-name, nav.tabs a').forEach(a => io.observe(a));
    }
  }
})();
