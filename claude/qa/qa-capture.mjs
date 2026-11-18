#!/usr/bin/env node
// QA capture tool for the /4n5rud-qa skill (claude-work-harness).
// Opens each page of a local (or approved test) web app, runs the given steps, records automatic findings
// (console errors, failed requests, horizontal overflow, broken images), and takes screenshots only where
// something needs a look: problem areas get numbered red boxes ("before"), and an optional CSS fix is applied
// in the browser to show the proposed result with green boxes ("after"). Nothing in the app is changed.
//
//   node qa-capture.mjs --spec qa-spec.json --out <folder>
//
// spec: { "baseUrl": "http://localhost:3000", "target": "local" | "test", "viewports": [1280, 390],
//         "storageState": "<project-relative file, optional>",
//         "pages": [ { "id": "orders", "path": "/orders", "ready": "css selector (optional)",
//                      "steps": [ { "action": "click"|"fill"|"press"|"wait", "selector": "...", "value": "...", "key": "..." } ],
//                      "issues": [ { "no": 1, "selector": "css", "label": "짧은 설명", "fixCss": "css for the after view (optional)" } ],
//                      "always": false } ] }
// Writes <out>/results.json and <out>/<page>-<viewport>-before.png / -after.png.
// Playwright is taken from the app itself, or from QA_PLAYWRIGHT_DIR (default: the e2e-harness folder in WORK_DIR).
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => (v.startsWith('--') ? a.concat([[v.slice(2), all[i + 1]]]) : a), []));
if (!args.spec || !args.out) { console.error('사용법: node qa-capture.mjs --spec qa-spec.json --out <폴더>'); process.exit(2); }
const spec = JSON.parse(fs.readFileSync(args.spec, 'utf8'));
fs.mkdirSync(args.out, { recursive: true });

// local by default; a remote test server only when the spec says "test"; production never
const url = new URL(spec.baseUrl);
const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
if (!loopback && spec.target !== 'test') { console.error('로컬 주소가 아닙니다. 승인된 시험 서버면 spec에 "target": "test"를 적으세요. 운영 서버는 점검하지 않습니다.'); process.exit(2); }
if (/(^|\.)(www\.)?[^.]+\.(com|co\.kr|kr|io|net)$/.test(url.hostname) && !/(dev|stg|stage|staging|test|qa)/i.test(url.hostname)) {
  console.error('운영 주소로 보여서 멈춥니다. 시험 서버 주소에 dev, stg, staging, test, qa 같은 표시가 없으면 사용자에게 확인하세요.'); process.exit(2);
}

function loadPlaywright() {
  const tries = [process.cwd(), process.env.QA_PLAYWRIGHT_DIR, process.env.WORK_DIR && path.join(process.env.WORK_DIR, 'e2e-harness')].filter(Boolean);
  for (const dir of tries) {
    try { return createRequire(path.join(dir, 'package.json'))('playwright'); } catch {}
  }
  console.error('Playwright를 찾지 못했습니다. 앱에 설치되어 있거나 QA_PLAYWRIGHT_DIR에 설치된 폴더를 지정하세요.'); process.exit(2);
}
const { chromium } = loadPlaywright();

const BOX_CSS = (color) => `
  .__qa_box{position:absolute;pointer-events:none;z-index:2147483646;border:3px solid ${color};border-radius:6px;box-shadow:0 0 0 2px #fff}
  .__qa_no{position:absolute;pointer-events:none;z-index:2147483647;background:${color};color:#fff;font:700 13px/1 -apple-system,sans-serif;padding:4px 7px;border-radius:99px;box-shadow:0 0 0 2px #fff}`;

async function mark(page, issues, color) {
  return page.evaluate(({ issues, css }) => {
    const st = document.createElement('style'); st.className = '__qa_style'; st.textContent = css; (document.head || document.documentElement).appendChild(st);
    const missing = [];
    // boxes hang off <html>, not <body>: a positioned or shifted body would move them off the target
    const host = document.documentElement;
    // bring the first marked element into the shot when it sits below the fold
    const first = issues.map((it) => it.selector && document.querySelector(it.selector)).find(Boolean);
    if (first) { const r = first.getBoundingClientRect(); if (r.top < 60 || r.bottom > innerHeight - 60) {   // keep a margin so the box and its number are not cut at the edge
      host.dataset.qaPad = host.style.paddingBottom; host.style.paddingBottom = '50vh';   // room to center a box at the very end of the page
      first.scrollIntoView({ block: 'center' }); } }
    for (const it of issues) {
      const els = it.selector ? [...document.querySelectorAll(it.selector)] : [];
      if (!els.length) { missing.push(it.no); continue; }
      els.slice(0, 6).forEach((el, i) => {
        const r = el.getBoundingClientRect(); const x = r.left + scrollX, y = r.top + scrollY;
        const b = document.createElement('div'); b.className = '__qa_box';
        Object.assign(b.style, { left: `${x - 4}px`, top: `${y - 4}px`, width: `${r.width + 8}px`, height: `${r.height + 8}px` });
        host.appendChild(b);
        if (i === 0) { const n = document.createElement('div'); n.className = '__qa_no'; n.textContent = String(it.no);
          Object.assign(n.style, { left: `${Math.max(0, x - 12)}px`, top: `${Math.max(0, y - 16)}px` }); host.appendChild(n); }
      });
    }
    return missing;
  }, { issues, css: BOX_CSS(color) });
}
const unmark = (page) => page.evaluate(() => { document.querySelectorAll('.__qa_box,.__qa_no,.__qa_style').forEach((e) => e.remove());
  const h = document.documentElement; if ('qaPad' in h.dataset) { h.style.paddingBottom = h.dataset.qaPad; delete h.dataset.qaPad; } });

async function runSteps(page, steps = []) {
  for (const s of steps) {
    if (s.action === 'click') await page.click(s.selector);
    else if (s.action === 'fill') await page.fill(s.selector, s.env ? (process.env[s.env] ?? '') : (s.value ?? ''));
    else if (s.action === 'press') await page.press(s.selector || 'body', s.key);
    else if (s.action === 'wait') await page.waitForSelector(s.selector, { timeout: spec.timeoutMs || 8000 });
  }
}

const results = { baseUrl: url.origin, startedAt: new Date().toISOString(), pages: [] };
const browser = await chromium.launch();
try {
  for (const vw of spec.viewports || [1280]) {
    const ctx = await browser.newContext({ viewport: { width: vw, height: vw < 700 ? 844 : 900 }, deviceScaleFactor: 2,
      storageState: spec.storageState && fs.existsSync(spec.storageState) ? spec.storageState : undefined });
    for (const pg of spec.pages) {
      const page = await ctx.newPage();
      const found = { console: [], requests: [], overflow: false, brokenImages: 0 };
      page.on('console', (m) => { if (m.type() === 'error') found.console.push(m.text().slice(0, 160)); });
      page.on('pageerror', (e) => found.console.push(String(e.message).slice(0, 160)));
      page.on('response', (r) => { if (r.status() >= 400) found.requests.push({ status: r.status(), path: new URL(r.url()).pathname.slice(0, 120) }); });
      const rec = { id: pg.id, path: pg.path, viewport: vw, ok: true, error: null, found, shots: {} };
      try {
        // 'load', not 'networkidle': apps that poll or keep a socket open never go idle
        await page.goto(url.origin + pg.path, { waitUntil: 'load', timeout: spec.timeoutMs || 15000 });
        await page.waitForLoadState('networkidle', { timeout: 3000 }).catch(() => {});
        if (pg.ready) await page.waitForSelector(pg.ready, { timeout: spec.timeoutMs || 8000 });
        await runSteps(page, pg.steps);
        await page.waitForTimeout(400);
        Object.assign(found, await page.evaluate(() => ({
          overflow: document.documentElement.scrollWidth > innerWidth + 1,
          brokenImages: [...document.images].filter((i) => i.complete && i.naturalWidth === 0).length })));
        const issues = pg.issues || [];
        const needShot = issues.length || pg.always || found.console.length || found.requests.length || found.overflow || found.brokenImages;
        if (needShot) {
          const base = `${pg.id}-${vw}`;
          rec.missing = await mark(page, issues, '#d32f2f');
          await page.screenshot({ path: path.join(args.out, `${base}-before.png`), fullPage: !!pg.fullPage });
          rec.shots.before = `${base}-before.png`;
          await unmark(page);
          const fix = issues.map((i) => i.fixCss).filter(Boolean).join('\n');
          if (fix) {
            await page.addStyleTag({ content: fix });
            await page.waitForTimeout(200);
            await mark(page, issues, '#1b7a3a');
            await page.screenshot({ path: path.join(args.out, `${base}-after.png`), fullPage: !!pg.fullPage });
            rec.shots.after = `${base}-after.png`;
          }
        }
      } catch (e) { rec.ok = false; rec.error = String(e.message).split('\n')[0].slice(0, 200);
        try { await page.screenshot({ path: path.join(args.out, `${pg.id}-${vw}-error.png`) }); rec.shots.error = `${pg.id}-${vw}-error.png`; } catch {} }
      results.pages.push(rec);
      await page.close();
    }
    await ctx.close();
  }
} finally { await browser.close(); }
results.finishedAt = new Date().toISOString();
fs.writeFileSync(path.join(args.out, 'results.json'), JSON.stringify(results, null, 2));
const bad = results.pages.filter((p) => !p.ok || p.found.console.length || p.found.requests.length || p.found.overflow || p.found.brokenImages || (p.missing || []).length);
console.log(`점검 ${results.pages.length}건, 자동으로 걸린 것 ${bad.length}건. 결과: ${path.join(args.out, 'results.json')}`);
