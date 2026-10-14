(() => {
  // Copy-to-clipboard for clone commands
  document.addEventListener('click', async (e) => {
    const btn = e.target.closest('button.copy');
    if (!btn) return;
    const text = btn.dataset.copy;
    try { await navigator.clipboard.writeText(text); }
    catch {
      const t = document.createElement('textarea');
      t.value = text; t.style.position = 'fixed'; t.style.opacity = '0';
      document.body.appendChild(t); t.select();
      try { document.execCommand('copy'); } catch {}
      t.remove();
    }
    btn.classList.add('done');
    setTimeout(() => btn.classList.remove('done'), 1500);
  });

  // Live filter on the index
  const q = document.getElementById('q');
  if (q) {
    const items = [...document.querySelectorAll('#index .repo')];
    const empty = document.getElementById('no-results');
    q.addEventListener('input', () => {
      const v = q.value.trim().toLowerCase();
      let shown = 0;
      items.forEach(li => {
        const hit = !v || li.dataset.name.includes(v) || li.textContent.toLowerCase().includes(v);
        li.hidden = !hit; if (hit) shown++;
      });
      if (empty) empty.hidden = shown > 0;
    });
  }

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
