#!/usr/bin/env python3
"""Review log viewer + dashboard, stdlib only.

  .review-tools/serve.py [--port 38500]     ->  http://localhost:38500/

/          dashboard: live sessions, per-AI/per-model adoption stats, smoke button
/log/<f>   one session, auto-refreshing while reviews run
The markdown session files under log/ stay the source of truth; this only reads
them (plus POST /api/smoke which runs smoke.sh).
"""
import argparse, html, json, os, re, subprocess, threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
LOGDIR = os.path.join(BASE, "log")
CLOSEDDIR = os.path.join(LOGDIR, "closed")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.md$")
VERDICT = re.compile(r"(?:^|\s)(\d+):(fix|fp|skip|dup)(?:/([hml]))?")
SUMMARY = re.compile(r"<summary>(.+?) — \((\w+), `(.+?)`\) — (.*)</summary>")
SEV_ICON = {"high": "🔴", "med": "🟡", "low": "🟢"}
SEV_WORD = {"h": "high", "m": "med", "l": "low"}
VLABEL = {"fix": "採用", "fp": "誤検知", "skip": "対応せず", "dup": "既報"}
VICON = {"fix": "✅", "fp": "❌", "skip": "⏭", "dup": "♻️"}
AI_ICON = {"codex": "⚡", "copilot": "🐙", "agy": "✨", "vllm": "🦙"}
KIND_ICON = {"commit": "📝", "branch": "🚀"}

def ai_label(ai):
    return f'{AI_ICON.get(ai, "🤖")} {ai}'
STATS_SINCE = "20260714"  # first day with numbered findings + structured verdicts

# ---------- parsing ----------

def split_cells(line):
    cells = re.split(r"(?<!\\)\|", line.strip())
    return [c.replace("\\|", "|").strip() for c in cells[1:-1]]

def parse_verdicts(resp):
    out = {}
    ms = list(VERDICT.finditer(resp))
    for i, m in enumerate(ms):
        end = ms[i + 1].start() if i + 1 < len(ms) else len(resp)
        reason = resp[m.end():end].strip().lstrip(":").strip()
        out[int(m.group(1))] = {"v": m.group(2), "sev": m.group(3), "reason": reason}
    return out

def parse_session(path):
    rounds, cur = [], None
    closed = pushline = None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        m = SUMMARY.search(line)
        if m:
            cur = {"ts": m.group(1), "kind": m.group(2), "ref": m.group(3),
                   "badges": m.group(4), "models": {}, "usage": {}, "rows": [], "response": ""}
            rounds.append(cur)
            continue
        if cur is None:
            if line == "<!-- SESSION CLOSED -->":
                closed = True
            continue
        if line.startswith("_models: ") and line.endswith("_"):
            for pair in line[9:-1].split(" · "):
                if "=" in pair:
                    ai, mv = pair.split("=", 1)
                    cur["models"][ai.strip()] = mv.strip()
        elif line.startswith("_usage: ") and line.endswith("_"):
            for pair in line[8:-1].split(" · "):
                if "=" in pair:
                    ai, uv = pair.split("=", 1)
                    cur["usage"][ai.strip()] = uv.strip()
        elif line.startswith("|") and not re.match(r"^\|[-| ]+\|$", line):
            cells = split_cells(line)
            if cells and cells[0] in ("#", "重大度"):
                continue
            if len(cells) == 5:
                num, sev, loc, ai, text = cells
            elif len(cells) == 4:
                num, (sev, loc, ai, text) = None, cells
            else:
                continue
            num = int(num) if num and num.isdigit() else None
            cur["rows"].append({"num": num, "sev": sev, "loc": loc, "ai": ai, "text": text})
        elif line.startswith("**Response:**"):
            cur["response"] = line[len("**Response:**"):].strip()
        elif line == "<!-- SESSION CLOSED -->":
            closed, cur = True, None
        elif line.startswith("✅"):
            pushline, cur = line, None
    for r in rounds:
        r["verdicts"] = parse_verdicts(r["response"])
        r["pending"] = r["response"] == "_(pending)_"
    return {"rounds": rounds, "closed": bool(closed), "pushline": pushline}

def list_sessions():
    out = []
    for d, closed in ((LOGDIR, False), (CLOSEDDIR, True)):
        try:
            names = os.listdir(d)
        except FileNotFoundError:
            continue
        for f in names:
            p = os.path.join(d, f)
            if SAFE_NAME.match(f) and os.path.isfile(p):
                repo, _, rest = f.partition("__")
                branch, _, ts = rest.partition("__")
                out.append({"file": f, "path": p, "closed": closed, "repo": repo,
                            "branch": branch, "ts": ts[:8], "mtime": os.path.getmtime(p)})
    return sorted(out, key=lambda s: -s["mtime"])

def state_version():
    vs = [os.path.getmtime(d) for d in (LOGDIR, CLOSEDDIR) if os.path.isdir(d)]
    for s in list_sessions():
        vs.append(s["mtime"])
    return max(vs, default=0)

# ---------- stats ----------

def parse_usage(s):
    """'2746tok' / '14200↑/21↓ 0.44cr' / '13290↑/57↓' -> (tokens, credits)"""
    tok, cr = 0, 0.0
    m = re.search(r"(\d+)tok", s)
    if m:
        tok += int(m.group(1))
    m = re.search(r"(\d+)↑/(\d+)↓", s)
    if m:
        tok += int(m.group(1)) + int(m.group(2))
    m = re.search(r"([\d.]+)cr", s)
    if m:
        cr = float(m.group(1))
    return tok, cr

def fmt_tok(n):
    return f"{n/1000:.1f}k" if n >= 10000 else str(n)

def sev_of(icon):
    for k in ("high", "med", "low"):
        if k in icon:
            return k
    return None

SEV_WEIGHT = {"high": 5, "med": 2, "low": 1}
SEV_JP = {"high": "高", "med": "中", "low": "低"}

def fix_score(s):
    return sum(SEV_WEIGHT[w] * s["fix_" + w] for w in SEV_WEIGHT)

def collect_stats():
    per_ai, per_model = {}, {}
    tot = {"sessions": 0, "rounds": 0, "findings": 0, "judged": 0, "fp": 0,
           "tok": 0, "cr": 0.0}
    def slot(d, k):
        return d.setdefault(k, {"findings": 0, "fix": 0, "fp": 0, "skip": 0,
                                "dup": 0, "rounds": 0, "warn": 0, "unparsed": 0,
                                "fix_high": 0, "fix_med": 0, "fix_low": 0,
                                "tok": 0, "cr": 0.0})
    for s in list_sessions():
        # pre-numbering sessions can never be judged (free-text Responses,
        # no models line) -- they'd only add "?" model rows and 0% noise
        if s["ts"] < STATS_SINCE:
            continue
        info = parse_session(s["path"])
        tot["sessions"] += 1
        for r in info["rounds"]:
            tot["rounds"] += 1
            for ai, us in r["usage"].items():
                utok, ucr = parse_usage(us)
                tot["tok"] += utok
                tot["cr"] += ucr
                for d, k in ((per_ai, ai), (per_model, f'{ai} · {r["models"].get(ai, "?")}')):
                    sl = slot(d, k)
                    sl["tok"] += utok
                    sl["cr"] += ucr
            seen_ai = set()
            for row in r["rows"]:
                ai = row["ai"]
                model = f'{ai} · {r["models"].get(ai, "?")}'
                for d, k in ((per_ai, ai), (per_model, model)):
                    sl = slot(d, k)
                    if ai not in seen_ai:
                        sl["rounds"] += 1
                    if "⚠" in row["sev"]:
                        sl["warn"] += 1
                    if "❓" in row["sev"]:
                        sl["unparsed"] += 1
                seen_ai.add(ai)
                if row["num"] is None and sev_of(row["sev"]) is None:
                    continue
                tot["findings"] += 1
                for d, k in ((per_ai, ai), (per_model, model)):
                    slot(d, k)["findings"] += 1
                vd = r["verdicts"].get(row["num"]) if row["num"] else None
                if vd:
                    tot["judged"] += 1
                    tot["fp"] += vd["v"] == "fp"
                    for d, k in ((per_ai, ai), (per_model, model)):
                        slot(d, k)[vd["v"]] += 1
                    if vd["v"] == "fix":
                        # 最終重大度 = /h /m /l 上書き、なければレビュアー評価に同意
                        fs = SEV_WORD[vd["sev"]] if vd["sev"] else sev_of(row["sev"])
                        if fs:
                            for d, k in ((per_ai, ai), (per_model, model)):
                                slot(d, k)["fix_" + fs] += 1
    return tot, per_ai, per_model

# ---------- rendering ----------

def md_inline(text):
    t = html.escape(text)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    return t

def chip(v, sev=None):
    extra = f"/{sev}" if sev else ""
    return f'<span class="chip {v}">{VICON[v]} {VLABEL[v]}{extra}</span>'

def render_response(resp):
    if resp == "_(pending)_":
        return '<span class="chip pending">✏️ Response 未記入</span>'
    def rep(m):
        return f'{" " if m.group(0)[0].isspace() else ""}<b>#{m.group(1)}</b> ' + chip(m.group(2), m.group(3))
    return VERDICT.sub(rep, md_inline(resp))

def render_round(r, open_):
    h = [f'<details{" open" if open_ else ""}><summary><b>{html.escape(r["ts"])}</b>'
         f' — {KIND_ICON.get(r["kind"], "")} {r["kind"]} <code>{html.escape(r["ref"])}</code> — {html.escape(r["badges"])}</summary>']
    if r["models"]:
        h.append('<div class="models">' + html.escape(" · ".join(f"{k}={v}" for k, v in r["models"].items())) + "</div>")
    if r["usage"]:
        h.append('<div class="models">🪙 ' + html.escape(" · ".join(f"{k}={v}" for k, v in r["usage"].items())) + "</div>")
    h.append("<table><tr><th>#</th><th>重大度</th><th>場所</th><th>AI</th><th>指摘</th><th>裁定</th></tr>")
    for row in r["rows"]:
        vd = r["verdicts"].get(row["num"]) if row["num"] else None
        vcell = ""
        if vd:
            vcell = chip(vd["v"], vd["sev"])
            rs = sev_of(row["sev"])
            if vd["sev"] and rs and SEV_WORD[vd["sev"]] != rs:
                vcell += f' <span class="nowrap">重大度 {SEV_ICON[rs]} → {SEV_ICON[SEV_WORD[vd["sev"]]]}</span>'
            vcell += f' {md_inline(vd["reason"])}' if vd["reason"] else ""
        elif row["num"] and r["pending"]:
            vcell = '<span class="dim">—</span>'
        h.append("<tr><td>%s</td><td class='nowrap'>%s</td><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
            row["num"] or "", html.escape(row["sev"]), html.escape(row["loc"]),
            ai_label(html.escape(row["ai"])), md_inline(row["text"]), vcell))
    h.append("</table>")
    h.append(f'<div class="resp"><b>Response:</b> {render_response(r["response"])}</div>')
    h.append("</details>")
    return "\n".join(h)

def page_session(name, closed):
    path = os.path.join(CLOSEDDIR if closed else LOGDIR, name)
    info = parse_session(path)
    repo, _, rest = name.partition("__")
    branch = rest.partition("__")[0]
    h = [f'<p><a href="/">← dashboard</a></p><h1>{html.escape(repo)} @ <code>{html.escape(branch)}</code>'
         f'{" <small>(closed)</small>" if info["closed"] else " 🔄"}</h1>']
    if info["pushline"]:
        h.append(f'<p>{md_inline(info["pushline"])}</p>')
    n = len(info["rounds"])
    for i, r in enumerate(info["rounds"]):
        h.append(render_round(r, open_=(i == n - 1 or r["pending"])))
    return "\n".join(h)

def stat_table(title, d):
    h = [f'<h2>{title}</h2><table class="compact"><tr><th></th><th>rounds</th><th>指摘</th><th>採用</th>'
         "<th>高</th><th>中</th><th>低</th>"
         "<th>誤検知</th><th>対応せず</th><th>既報</th><th>誤検知率</th><th>🪙 トークン</th><th>💳 費用</th><th>⚠</th><th>❓</th></tr>"]
    rows = []
    for k in sorted(d, key=lambda k: -d[k]["findings"]):
        s = d[k]
        judged = s["fix"] + s["fp"] + s["skip"] + s["dup"]
        rows.append((k, s, 100 * s["fp"] / judged if judged else None))
    # best-in-column highlight, only meaningful with something to compare
    # 採用は加重スコア (🔴5 🟡2 🟢1) で比較 -- 少数でも重要な指摘が勝てる
    best_fix = max((fix_score(s) for _, s, _ in rows), default=0) if len(rows) > 1 else 0
    rates = [r for _, _, r in rows if r is not None]
    best_rate = min(rates) if len(rows) > 1 and rates else None
    for k, s, rate in rows:
        fixc = ' class="best"' if best_fix and fix_score(s) == best_fix else ""
        ratec = ' class="best"' if rate is not None and rate == best_rate else ""
        ratestr = f'{rate:.0f}%' if rate is not None else '<span class="dim">—</span>'
        tokstr = fmt_tok(s["tok"]) if s["tok"] else '<span class="dim">—</span>'
        crstr = f'{s["cr"]:.2f}cr' if s["cr"] else '<span class="dim">—</span>'
        sevcells = "".join(f'<td>{s["fix_" + w] or "<span class=dim>—</span>"}</td>' for w in SEV_WEIGHT)
        h.append(f"<tr><td>{AI_ICON.get(k.split(' · ')[0], '🤖')} {html.escape(k)}</td><td>{s['rounds']}</td><td>{s['findings']}</td>"
                 f"<td{fixc}>{s['fix']}</td>{sevcells}<td>{s['fp']}</td><td>{s['skip']}</td><td>{s['dup']}</td>"
                 f"<td{ratec}>{ratestr}</td><td>{tokstr}</td><td>{crstr}</td><td>{s['warn']}</td><td>{s['unparsed']}</td></tr>")
    h.append("</table>")
    return "\n".join(h)

def session_table(items, closed):
    if not items:
        return '<p class="dim">なし</p>'
    h = ['<table class="compact"><tr><th>日時</th><th>セッション</th><th>ラウンド</th>'
         + ("" if closed else "<th>Response未記入</th>") + "</tr>"]
    for s in items:
        info = parse_session(s["path"])
        day = datetime.fromtimestamp(s["mtime"]).strftime("%Y-%m-%d %H:%M")
        link = (f'<a href="/log/{"closed/" if closed else ""}{s["file"]}">'
                f'<b>{html.escape(s["repo"])}</b> @ <code>{html.escape(s["branch"])}</code></a>')
        row = (f'<tr><td class="nowrap dim">{day}</td><td>{"✅ " if closed else "🔄 "}{link}</td>'
               f'<td>{len(info["rounds"])}</td>')
        if not closed:
            pend = sum(r["pending"] for r in info["rounds"])
            row += f'<td>{f"<b>✏️ {pend}件</b>" if pend else ""}</td>'
        h.append(row + "</tr>")
    h.append("</table>")
    return "\n".join(h)

def page_dashboard():
    tot, per_ai, per_model = collect_stats()
    sessions = list_sessions()
    h = ["<h1>📊 Review Dashboard</h1>",
         '<div class="smoke"><button onclick="smoke(this)">▶ reviewer スモークテスト</button>'
         '<pre id="smokeout"></pre></div>']
    rate = f'{100 * tot["fp"] / tot["judged"]:.0f}%' if tot["judged"] else "—"
    h.append('<div class="tiles">' + "".join(
        f'<div class="tile"><div class="n">{v}</div><div class="l">{l}</div></div>'
        for l, v in (("🗂 セッション", tot["sessions"]), ("🔁 ラウンド", tot["rounds"]),
                     ("🔍 指摘", tot["findings"]), ("⚖️ 裁定済", tot["judged"]), ("🎯 誤検知率", rate),
                     ("🪙 トークン", fmt_tok(tot["tok"])), ("💳 Copilot", f'{tot["cr"]:.2f}cr'))) + "</div>")
    h.append(f'<p class="dim">集計対象: {STATS_SINCE[:4]}-{STATS_SINCE[4:6]}-{STATS_SINCE[6:]} 以降のセッション (それ以前は裁定データなし)</p>')
    h.append('<div class="cols"><div>')
    h.append("<h2>🔄 進行中</h2>")
    h.append(session_table([s for s in sessions if not s["closed"]], closed=False))
    h.append("<h2>✅ 完了 (push成立)</h2>")
    h.append(session_table([s for s in sessions if s["closed"]][:15], closed=True))
    h.append("</div><div>")
    h.append(stat_table("🤖 AI別", per_ai))
    h.append(stat_table("🧠 モデル別", per_model))
    h.append('<p class="dim">高/中/低 = 採用指摘の書き手評価 (裁定の /h /m /l、なければレビュアー評価に同意)。'
             '採用のハイライトは加重スコア 高5 中2 低1</p>')
    h.append("</div></div>")
    return "\n".join(h)

CSS = """
:root{--bg:#fff;--fg:#1a1a1a;--line:#ddd;--dim:#888;--accent:#0969da;--card:#f6f8fa}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--line:#30363d;--dim:#8b949e;--accent:#58a6ff;--card:#161b22}}
body{background:var(--bg);color:var(--fg);font:15px/1.6 system-ui,sans-serif;max-width:1750px;margin:0 auto;padding:1em 1.5em}
.cols{display:grid;grid-template-columns:1fr 1fr;gap:0 2.5em;align-items:start}
@media(max-width:1200px){.cols{grid-template-columns:1fr}}
th{white-space:nowrap} .compact td{white-space:nowrap}
td.best{background:rgba(45,164,78,.15);font-weight:600}
a{color:var(--accent)} code{background:var(--card);padding:1px 5px;border-radius:4px;font-size:.9em}
table{border-collapse:collapse;width:100%;margin:.5em 0}
th,td{border:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}
th{background:var(--card)} .nowrap{white-space:nowrap}
details{border:1px solid var(--line);border-radius:8px;padding:.4em .8em;margin:.6em 0}
summary{cursor:pointer} .models{color:var(--dim);font-size:.85em;margin:.3em 0}
.resp{margin:.4em 0;padding:.4em .6em;background:var(--card);border-radius:6px}
.chip{display:inline-block;padding:0 8px;border-radius:10px;font-size:.85em;color:#fff}
.chip.fix{background:#2da44e}.chip.fp{background:#cf222e}.chip.skip{background:#6e7781}
.chip.dup{background:#6e7781}.chip.pending{background:#bf8700}
.tiles{display:flex;gap:1em;flex-wrap:wrap;margin:1em 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:.6em 1.2em;text-align:center}
.tile .n{font-size:1.6em;font-weight:700}.tile .l{color:var(--dim);font-size:.85em}
.dim{color:var(--dim)} .smoke{margin:.8em 0}
button{font:inherit;padding:.3em 1em;border-radius:6px;border:1px solid var(--line);background:var(--card);color:var(--fg);cursor:pointer}
#smokeout:empty{display:none}#smokeout{background:var(--card);padding:.6em;border-radius:6px;white-space:pre-wrap}
"""
JS = """
let v=null;
async function tick(){try{const j=await(await fetch('/api/state')).json();
 if(v===null)v=j.v;else if(j.v!==v){v=j.v;
  document.getElementById('c').innerHTML=await(await fetch(location.pathname+'?fragment=1')).text();}
}catch(e){}}
setInterval(tick,2000);
async function smoke(b){const o=document.getElementById('smokeout');b.disabled=true;
 o.textContent='実行中… (最大2分半)';
 try{o.textContent=await(await fetch('/api/smoke',{method:'POST'})).text();}
 catch(e){o.textContent='error: '+e;}b.disabled=false;}
"""

def wrap(title, body):
    return (f"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{html.escape(title)}</title><style>{CSS}</style>"
            f"<div id=c>{body}</div><script>{JS}</script>")

# ---------- http ----------

SMOKE_LOCK = threading.Lock()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path, _, q = self.path.partition("?")
        frag = "fragment=1" in q
        try:
            if path == "/":
                body, title = page_dashboard(), "Review Dashboard"
            elif path == "/api/state":
                return self.send(200, json.dumps({"v": state_version()}), "application/json")
            elif path.startswith("/log/"):
                rest = path[len("/log/"):]
                closed = rest.startswith("closed/")
                name = rest[len("closed/"):] if closed else rest
                if not SAFE_NAME.match(name) or not os.path.isfile(os.path.join(CLOSEDDIR if closed else LOGDIR, name)):
                    return self.send(404, "not found", "text/plain")
                body, title = page_session(name, closed), name
            else:
                return self.send(404, "not found", "text/plain")
        except Exception as e:
            return self.send(500, f"render error: {html.escape(str(e))}", "text/plain")
        self.send(200, body if frag else wrap(title, body))

    def do_POST(self):
        if self.path != "/api/smoke":
            return self.send(404, "not found", "text/plain")
        if not SMOKE_LOCK.acquire(blocking=False):
            return self.send(409, "smoke test already running", "text/plain")
        try:
            r = subprocess.run([os.path.join(BASE, "smoke.sh")], capture_output=True,
                               text=True, timeout=200)
            out = r.stdout + r.stderr + ("" if r.returncode == 0 else f"\nexit {r.returncode}")
        except subprocess.TimeoutExpired:
            out = "smoke.sh timed out (200s)"
        finally:
            SMOKE_LOCK.release()
        self.send(200, out, "text/plain; charset=utf-8")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=38500)
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), H)
    print(f"review viewer: http://localhost:{args.port}/")
    srv.serve_forever()
