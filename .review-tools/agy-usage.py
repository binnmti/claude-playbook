#!/usr/bin/env python3
"""agy はトークン数をどこにも出力しないが、会話 DB (protobuf) には記録している。
gen_metadata.#1(chatModel).#4(usage) の varint を読む。フィールド番号は
tokscale (junhoyeo/tokscale, antigravity_cli.rs) の解析結果に依拠した非公式
スキーマなので、agy 更新で沈黙する可能性あり (その場合 usage 行が消えるだけ)。

usage: agy-usage.py <start-epoch>
start-epoch 以降に更新された会話 DB の全 generation を合算し、
"tokens in=N out=M" を出力 (in=システム+新規+cacheRead, out=本文+thinking)。
"""
import glob, os, sqlite3, sys

def fields(buf):
    i, n = 0, len(buf)
    while i < n:
        v = s = 0
        while True:
            b = buf[i]; i += 1
            v |= (b & 0x7F) << s; s += 7
            if not b & 0x80: break
        fno, wt = v >> 3, v & 7
        if wt == 0:
            v = s = 0
            while True:
                b = buf[i]; i += 1
                v |= (b & 0x7F) << s; s += 7
                if not b & 0x80: break
            yield fno, wt, v
        elif wt == 2:
            ln = s = 0
            while True:
                b = buf[i]; i += 1
                ln |= (b & 0x7F) << s; s += 7
                if not b & 0x80: break
            yield fno, wt, buf[i:i+ln]; i += ln
        elif wt == 5:
            i += 4
        elif wt == 1:
            i += 8
        else:
            return

def field(buf, no):
    for f, w, v in fields(buf):
        if f == no and w == 2:
            return v
    return None

start = float(sys.argv[1])
tin = tout = 0
for db in glob.glob(os.path.expanduser("~/.gemini/antigravity-cli/conversations/*.db")):
    if os.path.getmtime(db) < start:
        continue
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = conn.execute("SELECT data FROM gen_metadata").fetchall()
    except sqlite3.Error:
        continue
    for (blob,) in rows:
        chat = field(blob, 1)
        usage = chat is not None and field(chat, 4)
        if not usage:
            continue
        u = {f: v for f, w, v in fields(usage) if w == 0}
        tin += u.get(1, 0) + u.get(2, 0) + u.get(5, 0)
        tout += u.get(9, 0) + u.get(10, 0)
if tin or tout:
    print(f"tokens in={tin} out={tout}")
