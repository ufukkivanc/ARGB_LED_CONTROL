#!/usr/bin/env python
"""Gömülü LED kontrol arayüzünü (firmware/src/wled/control_page.h) GERÇEK tarayıcıda sınar.

Düzenek: firmware'deki sayfa HTML'i olduğu gibi sahte bir WLED sunucusundan (aynı JSON/WS sözleşmesi) sunulur;
başsız Chrome iPhone görünümünde (390x844) Chrome DevTools Protocol ile sürülür. ESP32 GEREKMEZ.

Sınananlar: render, 20 efekt, aç/kapat, parlaklık, renk çarkı/hazır renk, efekt/hız/yoğunluk, kanal seçimi,
readonly (kontroller devre dışı + gönderim yok), off (kontrol arayüzü yok), WS hata çerçevesi, WS yokken
HTTP yedeği (POST /json/state) ve yoklama. Sayfanın gönderdiği komutlar `commands.jsonl` olarak kaydedilir
ve C++ eşleme koduyla (wled_map_test --replay) doğrulanır.

Gereksinim: Python `websockets` (>=13), Google Chrome. Kullanım: python browser_ui_test.py <çıktı_klasörü>
"""
import asyncio
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from http import HTTPStatus

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.http11 import Response

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="ui_test_")
os.makedirs(OUT, exist_ok=True)
CHROME = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
PORT = 8123
CDP_PORT = 9223

src = open(os.path.join(HERE, "..", "src", "wled", "control_page.h"), encoding="utf-8").read()
pages = re.findall(r'R"HTML\((.*?)\)HTML"', src, re.S)
CONTROL_HTML, OFF_HTML = pages[0], pages[1]
EFFECTS = ["Solid", "Rainbow", "Rainbow Cycle", "Breathe", "Color Fade", "Color Wipe", "Running Lights",
           "Theater Chase", "Fire", "Meteor Rain", "Twinkle", "Sparkle", "Police Lights", "Wave",
           "Gradient Move", "Comet", "Pulse", "Random Colors", "Gradient", "Music Reactive"]

passed, failed = 0, []


def check(cond, name, extra=""):
    global passed
    suffix = ("  [" + extra + "]") if extra else ""
    if cond:
        passed += 1
        print("  ok   " + name + suffix)
    else:
        failed.append(name)
        print("  FAIL " + name + suffix)


# ───────────────────────── sahte cihaz ─────────────────────────
class Mock:
    def __init__(self, mode="control", channels=1, ws=True):
        self.mode = mode
        self.ws_enabled = ws
        self.eff = "ok"        # ok | buggy | fail500 | flaky | down | si
        self.eff_hits = []     # istenen yollar
        self.clients = set()
        self.log = []
        self.ch = [dict(id=i, len=10 * (i + 1), on=True, bri=200, col=[[108, 99, 255], [0, 210, 255], [0, 0, 0]],
                        fx=3, sx=140, ix=128, rev=False, apal=[]) for i in range(channels)]
        self.cfg_n = [10 * (i + 1) if i < channels else 0 for i in range(4)]
        self.reboot_calls = 0

    def setlen(self, i, n):
        if not (0 <= i < 4) or n < 0 or n > 512:
            return False
        if sum(x for j, x in enumerate(self.cfg_n) if j != i) + n > 1024:
            return False
        self.cfg_n[i] = n
        new = []
        for j in range(4):
            if self.cfg_n[j] > 0:
                old = next((c for c in self.ch if c["id"] == j), None)
                c = old or dict(id=j, len=0, on=True, bri=200, col=[[108, 99, 255], [0, 210, 255], [0, 0, 0]],
                                fx=3, sx=140, ix=128, rev=False, apal=[])
                c["len"] = self.cfg_n[j]
                new.append(c)
        self.ch = new
        return True

    def state(self):
        segs, off = [], 0
        for c in self.ch:
            s = dict(c)
            s["pal"] = 1 if c["apal"] else 0
            s["start"], s["stop"] = off, off + c["len"]
            off += c["len"]
            segs.append(s)
        return {"on": any(c["on"] for c in self.ch), "bri": max(c["bri"] for c in self.ch), "seg": segs}

    def info(self):
        return {"ver": "0.14.0", "name": "Test LED", "ip": "192.168.1.50", "brand": "ESP32-ARGB", "mac": "a1b2c3d4e5f6",
                "leds": {"count": sum(c["len"] for c in self.ch)}, "wifi": {"rssi": -57, "signal": 86},
                "uptime": 93784, "freeheap": 190000, "ws": len(self.clients), "access": self.mode,
                "argb": {"maxlen": 512, "maxtotal": 1024, "warnlen": 300, "warntotal": 600, "maxpal": 5, "reboot": False,
                         "ch": [{"id": i, "en": self.cfg_n[i] > 0, "n": self.cfg_n[i]} for i in range(4)]}}

    def frame(self):
        return {"state": self.state(), "info": self.info()}

    def apply(self, cmd):
        self.log.append(cmd)
        if "on" in cmd:
            v = cmd["on"] if cmd["on"] != "t" else not any(c["on"] for c in self.ch)
            for c in self.ch:
                c["on"] = v
        if "bri" in cmd:
            m = max(c["bri"] for c in self.ch)
            for c in self.ch:
                c["bri"] = cmd["bri"] if m == 0 else min(255, round(c["bri"] * cmd["bri"] / m))
        for e in (cmd.get("argb") or {}).get("leds", []):
            self.setlen(e["id"], e["n"])
        if (cmd.get("argb") or {}).get("reboot"):
            self.reboot_calls += 1
        seg = cmd.get("seg")
        if isinstance(seg, dict):
            seg = [seg]
        for i, s in enumerate(seg or []):
            idx = s.get("id", i)
            if idx >= len(self.ch):
                continue
            c = self.ch[idx]
            for k in ("on", "bri", "fx", "sx", "ix", "rev"):
                if k in s:
                    c[k] = s[k]
            if "apal" in s:
                c["apal"] = [list(x[:3]) for x in s["apal"][:5]]
            for j, col in enumerate(s.get("col", [])[:2]):
                if col:
                    c["col"][j] = col[:3]


MOCK = Mock()


async def broadcast():
    msg = json.dumps(MOCK.frame())
    for c in list(MOCK.clients):
        try:
            await c.send(msg)
        except Exception:
            MOCK.clients.discard(c)


def process_request(conn, req):
    path = req.path.split("?")[0]
    if path == "/ws":
        if not MOCK.ws_enabled:
            return conn.respond(HTTPStatus.NOT_FOUND, "no ws\n")
        return None   # WebSocket el sıkışması
    if MOCK.mode == "off" and path.startswith("/json"):
        return conn.respond(HTTPStatus.FORBIDDEN, '{"error":1,"message":"wled_compat_disabled"}')

    def js(obj, status=HTTPStatus.OK):
        r = conn.respond(status, json.dumps(obj))
        r.headers["Content-Type"] = "application/json"
        return r

    if path == "/":
        r = conn.respond(HTTPStatus.OK, OFF_HTML if MOCK.mode == "off" else CONTROL_HTML)
        r.headers["Content-Type"] = "text/html; charset=utf-8"
        return r
    MOCK.eff_hits.append(path)
    if path == "/json/si":
        f = MOCK.frame()
        if MOCK.eff == "si":
            f["effects"] = EFFECTS      # yalnızca si/json yolunda effects veren cihaz
        return js(f)
    if path == "/json":
        if MOCK.eff in ("si", "down"):
            return js({"error": 1, "message": "nope"}, HTTPStatus.NOT_FOUND)
        f = MOCK.frame()
        f["effects"] = EFFECTS
        f["palettes"] = ["Default"]
        return js(f)
    if path == "/json/eff":
        if MOCK.eff == "buggy":      # gerçek cihazdaki hata: /json/eff tam /json nesnesini döndürüyordu
            f = MOCK.frame()
            f["effects"] = EFFECTS
            return js(f)
        if MOCK.eff == "fail500":
            return js({"error": 1, "message": "boom"}, HTTPStatus.INTERNAL_SERVER_ERROR)
        if MOCK.eff == "down":
            return js({"error": 3, "message": "rate_limited"}, HTTPStatus.TOO_MANY_REQUESTS)
        if MOCK.eff == "flaky" and MOCK.eff_hits.count("/json/eff") == 1:
            return js({"error": 3, "message": "rate_limited"}, HTTPStatus.TOO_MANY_REQUESTS)
        if MOCK.eff == "si":
            return js({"error": 1, "message": "nope"}, HTTPStatus.NOT_FOUND)
        return js(EFFECTS)
    if path == "/json/state":
        return js(MOCK.state())
    return conn.respond(HTTPStatus.NOT_FOUND, "nf\n")


async def ws_handler(ws):
    if MOCK.mode != "off":
        MOCK.clients.add(ws)
        await ws.send(json.dumps(MOCK.frame()))
    try:
        async for m in ws:
            if m == "p":
                await ws.send("pong")
                continue
            cmd = json.loads(m)
            writes = any(k in cmd for k in ("on", "bri", "seg"))
            if writes and MOCK.mode != "control":
                await ws.send(json.dumps({"error": 1, "message": "wled_read_only"}))
                continue
            MOCK.apply(cmd)
            await broadcast()
    finally:
        MOCK.clients.discard(ws)


# ───────────────────────── CDP istemcisi ─────────────────────────
class Page:
    def __init__(self, ws):
        self.ws = ws
        self.i = 0
        self.waiters = {}
        self.events = []

    async def run(self):
        async for m in self.ws:
            j = json.loads(m)
            if "id" in j and j["id"] in self.waiters:
                self.waiters.pop(j["id"]).set_result(j)
            else:
                self.events.append(j)

    async def cmd(self, method, **params):
        self.i += 1
        fut = asyncio.get_event_loop().create_future()
        self.waiters[self.i] = fut
        await self.ws.send(json.dumps({"id": self.i, "method": method, "params": params}))
        r = await asyncio.wait_for(fut, 20)
        if "error" in r:
            raise RuntimeError(str(r["error"]))
        return r.get("result", {})

    async def ev(self, expr):
        r = await self.cmd("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True)
        if "exceptionDetails" in r:
            raise RuntimeError(json.dumps(r["exceptionDetails"])[:300])
        return r["result"].get("value")

    async def wait(self, expr, timeout=6.0):
        end = time.time() + timeout
        while time.time() < end:
            try:
                if await self.ev(expr):
                    return True
            except RuntimeError:
                pass
            await asyncio.sleep(0.05)
        return False

    async def shot(self, name):
        r = await self.cmd("Page.captureScreenshot", format="png", captureBeyondViewport=True)
        path = os.path.join(OUT, name)
        open(path, "wb").write(base64.b64decode(r["data"]))
        return path


async def open_page(chrome_port, url):
    req = urllib.request.Request(f"http://127.0.0.1:{chrome_port}/json/new?{url}", method="PUT")
    info = json.loads(urllib.request.urlopen(req).read())
    ws = await connect(info["webSocketDebuggerUrl"], max_size=None)
    p = Page(ws)
    asyncio.get_event_loop().create_task(p.run())
    await p.cmd("Page.enable")
    await p.cmd("Runtime.enable")
    await p.cmd("Emulation.setDeviceMetricsOverride", width=390, height=844, deviceScaleFactor=2, mobile=True)
    await p.cmd("Emulation.setUserAgentOverride",
                userAgent="Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148")
    return p, info["id"]


async def load(chrome_port, mode="control", channels=1, ws=True):
    global MOCK
    MOCK = Mock(mode, channels, ws)
    p, tid = await open_page(chrome_port, "about:blank")
    await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
    return p, tid


async def close(chrome_port, p, tid):
    await p.ws.close()
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{chrome_port}/json/close/{tid}").read()
    except Exception:
        pass


async def mouse(p, x, y):
    for t in ("mousePressed", "mouseReleased"):
        await p.cmd("Input.dispatchMouseEvent", type=t, x=x, y=y, button="left", clickCount=1, buttons=1 if t == "mousePressed" else 0)
        await asyncio.sleep(0.05)


async def main():
    chrome = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--no-sandbox", f"--remote-debugging-port={CDP_PORT}",
                               f"--user-data-dir={os.path.join(OUT, 'profile')}", "--no-first-run", "about:blank"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{CDP_PORT}/json/version").read()
                break
            except Exception:
                await asyncio.sleep(0.1)
        async with serve(ws_handler, "127.0.0.1", PORT, process_request=process_request):
            await scenarios()
    finally:
        chrome.terminate()


async def scenarios():
    global MOCK
    cp = CDP_PORT

    print("[control modu: render]")
    p, tid = await load(cp, "control", channels=2)
    check(await p.wait("document.querySelectorAll('#fg .fx').length===20"), "20 efekt düğmesi çizildi")
    check(await p.ev("document.getElementById('nm').textContent") == "Test LED", "cihaz adı")
    check(await p.wait("!document.getElementById('ctl').disabled"), "kontroller etkin (control)")
    check(await p.ev("document.getElementById('ban').className.includes('hide')"), "uyarı bandı gizli")
    check(await p.wait("document.getElementById('dot').className.includes('on')"), "WebSocket canlı göstergesi")
    check(await p.ev("document.querySelectorAll('#chs .chip').length") == 2, "2 kanal çipi")
    check("Canlı" in await p.ev("document.getElementById('kv').textContent"), "bağlantı durumu 'Canlı'")
    check("-57" in await p.ev("document.getElementById('kv').textContent"), "Wi-Fi sinyali (dBm) gösteriliyor")
    check(await p.ev("document.getElementById('pw').className") == "on", "güç düğmesi açık")
    check(await p.ev("document.documentElement.scrollWidth<=390"), "yatay taşma yok (390 px)")
    await p.shot("control_2ch.png")

    print("[control modu: komutlar]")
    n0 = len(MOCK.log)
    await p.ev("document.getElementById('pw').click()")
    check(await p.wait("document.getElementById('pw').className===''"), "aç/kapat: sunucu çerçevesiyle UI güncellendi")
    check(MOCK.log[n0:] == [{"on": False}], "aç/kapat komutu {'on':false}")
    await p.ev("document.getElementById('pw').click()")
    await p.wait("document.getElementById('pw').className==='on'")

    await p.ev("(function(){var e=document.getElementById('br');e.value=90;e.dispatchEvent(new Event('input'))})()")
    check(await p.wait("true") and await _until(lambda: {"bri": 90} in MOCK.log), "parlaklık komutu {'bri':90} (tüm kanallar)")

    await p.ev("document.querySelectorAll('#fg .fx')[5].click()")
    check(await _until(lambda: {"seg": [{"id": 0, "fx": 5}, {"id": 1, "fx": 5}]} in MOCK.log), "efekt 5 seçimi: tüm seçili kanallara")
    check(await p.wait("document.querySelectorAll('#fg .fx')[5].className.includes('s')"), "seçili efekt vurgulandı (sunucu doğruladı)")

    await p.ev("document.querySelectorAll('#pr .pre')[8].click()")   # mavi
    check(await _until(lambda: any(m.get("seg") and m["seg"][0].get("col") == [[0, 70, 255]] for m in MOCK.log)), "hazır renk -> col[0]")
    # 2. renk yuvası
    await p.ev("document.getElementById('s1').click()")
    await p.ev("document.querySelectorAll('#pr .pre')[0].click()")   # kırmızı
    check(await _until(lambda: any(m.get("seg") and m["seg"][0].get("col") == [None, [255, 0, 0]] for m in MOCK.log)), "2. renk -> col[null,[r,g,b]]")
    await p.ev("document.getElementById('s0').click()")

    # renk çarkı: gerçek fare tıklaması
    await p.ev("document.getElementById('wc').scrollIntoView({block:'center'})")
    await asyncio.sleep(0.2)
    box = await p.ev("(function(){var r=document.getElementById('wc').getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()")
    n1 = len(MOCK.log)
    await mouse(p, box[0] + box[2] * 0.85, box[1] + box[3] * 0.5)   # sağ kenar ≈ kırmızı tonu
    check(await _until(lambda: any(m.get("seg") and m["seg"][0].get("col") and m["seg"][0]["col"][0][0] > 200 for m in MOCK.log[n1:])), "renk çarkına dokunuş -> col (kırmızı baskın)")

    await p.ev("(function(){var e=document.getElementById('sp');e.value=255;e.dispatchEvent(new Event('input'))})()")
    check(await _until(lambda: any(m.get("seg") and m["seg"][0].get("sx") == 255 for m in MOCK.log)), "hız -> sx")
    await p.ev("(function(){var e=document.getElementById('ix');e.value=10;e.dispatchEvent(new Event('input'))})()")
    check(await _until(lambda: any(m.get("seg") and m["seg"][0].get("ix") == 10 for m in MOCK.log)), "yoğunluk -> ix")
    await p.ev("(function(){var e=document.getElementById('rv');e.checked=true;e.dispatchEvent(new Event('change'))})()")
    check(await _until(lambda: any(m.get("seg") and m["seg"][0].get("rev") is True for m in MOCK.log)), "ters yön -> rev")

    # kanal seçimi: yalnızca kanal 2
    await p.ev("document.querySelectorAll('#chs .chip')[0].click()")
    check(await p.wait("document.querySelectorAll('#chs .chip.s').length===1"), "kanal 1 çıkarıldı (tek kanal seçili)")
    n2 = len(MOCK.log)
    await p.ev("document.getElementById('pw').click()")
    check(await _until(lambda: MOCK.log[n2:] == [{"seg": [{"id": 1, "on": False}]}]), "tek kanal seçiliyken güç: seg-düzeyi {id:1,on:false}")
    await p.ev("(function(){var e=document.getElementById('br');e.value=40;e.dispatchEvent(new Event('input'))})()")
    check(await _until(lambda: {"seg": [{"id": 1, "bri": 40}]} in MOCK.log), "tek kanal parlaklığı seg-düzeyi")
    check(MOCK.ch[0]["on"] is True and MOCK.ch[0]["bri"] != 40, "seçili olmayan kanal 1 etkilenmedi")
    await p.ev("document.querySelectorAll('#chs .chip')[1].click()")   # son seçili kanal kaldırılamaz
    check(await p.ev("document.querySelectorAll('#chs .chip.s').length") >= 1, "en az bir kanal her zaman seçili")

    print("[yetenek tablosu]")
    await p.ev("document.querySelectorAll('#fg .fx')[0].click()")   # Solid: hız/yoğunluk yok
    await _until(lambda: MOCK.ch[1]["fx"] == 0)
    check(await p.wait("document.getElementById('spw').className==='dim' && document.getElementById('inw').className==='dim'"), "Solid: hız ve yoğunluk devre dışı")
    await p.ev("document.querySelectorAll('#fg .fx')[8].click()")   # Fire: renk yok
    await _until(lambda: MOCK.ch[1]["fx"] == 8)
    check(await p.wait("document.getElementById('cw').className==='dim'"), "Fire: renk çarkı devre dışı (renk kullanmaz)")
    await close(cp, p, tid)

    print("[readonly modu]")
    p, tid = await load(cp, "readonly")
    check(await p.wait("document.querySelectorAll('#fg .fx').length===20"), "readonly: sayfa yüklendi")
    check(await p.wait("document.getElementById('ctl').disabled===true"), "readonly: kontroller devre dışı")
    check(await p.ev("!document.getElementById('ban').className.includes('hide')") and
          "Salt okunur" in await p.ev("document.getElementById('ban').textContent"), "readonly: kullanıcıya salt okunur uyarısı")
    n3 = len(MOCK.log)
    await p.ev("document.getElementById('pw').click();document.querySelectorAll('#fg .fx')[4].click()")
    await asyncio.sleep(0.4)
    check(len(MOCK.log) == n3, "readonly: hiçbir komut gönderilmedi")
    await p.shot("readonly.png")
    await close(cp, p, tid)

    print("[off modu]")
    p, tid = await load(cp, "off")
    check(await p.wait("document.body.textContent.includes('kapalı')"), "off: bilgi sayfası")
    check(await p.ev("document.getElementById('fg')===null && document.getElementById('pw')===null"), "off: kontrol arayüzü sunulmadı")
    check(await p.ev("document.querySelector('a[href=\"/setup\"]')!==null"), "off: /setup bağlantısı korunuyor")
    await close(cp, p, tid)

    print("[hata yönetimi: WS hata çerçevesi]")
    p, tid = await load(cp, "control")
    await p.wait("document.querySelectorAll('#fg .fx').length===20")
    await p.wait("document.getElementById('dot').className.includes('on')")   # WS açık olmadan tıklama yarışını önle
    MOCK.mode = "readonly"   # çalışırken yetki düşürüldü: sayfa hâlâ 'control' sanıyor
    await p.ev("document.getElementById('pw').click()")
    check(await p.wait("document.getElementById('tt').textContent.includes('Salt okunur') && !document.getElementById('tt').className.includes('hide')"),
          "WS 'wled_read_only' hatası kullanıcıya gösterildi")
    await close(cp, p, tid)

    print("[WS yok: HTTP yedeği ve yoklama]")
    p, tid = await open_page(cp, "about:blank")
    MOCK = Mock("control", 1, ws=False)
    posts = []
    await p.cmd("Fetch.enable", patterns=[{"urlPattern": "*/json/state", "requestStage": "Request"}])

    async def intercept():
        seen = 0
        while True:
            for e in p.events[seen:]:
                if e.get("method") == "Fetch.requestPaused" and e["params"]["request"]["method"] == "POST":
                    body = json.loads(e["params"]["request"]["postData"])
                    posts.append(body)
                    MOCK.apply({k: v for k, v in body.items() if k != "v"})
                    out = base64.b64encode(json.dumps(MOCK.state()).encode()).decode()
                    await p.cmd("Fetch.fulfillRequest", requestId=e["params"]["requestId"], responseCode=200,
                                responseHeaders=[{"name": "Content-Type", "value": "application/json"}], body=out)
                elif e.get("method") == "Fetch.requestPaused":
                    await p.cmd("Fetch.continueRequest", requestId=e["params"]["requestId"])
            seen = len(p.events)
            await asyncio.sleep(0.03)
    task = asyncio.get_event_loop().create_task(intercept())
    await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
    check(await p.wait("document.querySelectorAll('#fg .fx').length===20"), "WS yokken sayfa yine de yüklendi (HTTP)")
    check(await p.wait("document.getElementById('kv').textContent.includes('Yoklama')"), "bağlantı durumu 'Yoklama'")
    check(await p.ev("document.getElementById('dot').className.includes('po')"), "turuncu bağlantı göstergesi")
    await p.ev("document.getElementById('pw').click()")
    check(await _until(lambda: any(b.get("on") is False and b.get("v") is True for b in posts)), "HTTP yedeği: POST /json/state {'on':false,'v':true}")
    check(await p.wait("document.getElementById('pw').className===''"), "POST yanıtı UI'ya yansıdı")
    MOCK.ch[0]["bri"] = 33   # cihaz tarafında değişiklik: yoklama yakalamalı
    check(await p.wait("document.getElementById('bv').textContent==='13%'", 8), "yoklama cihaz değişikliğini yansıttı")
    task.cancel()
    await close(cp, p, tid)


    print("[efekt listesi: yanıt biçimi ve yedek yollar]")
    for mode, name, expect_hits in [
        ("buggy", "/json/eff tam /json nesnesi döndürüyor (gerçek cihaz hatası)", None),
        ("fail500", "/json/eff HTTP 500 -> /json yedeği", ["/json/eff", "/json"]),
        ("flaky", "/json/eff ilk istekte 429 -> yedek/yeniden deneme", None),
        ("si", "/json/eff ve /json başarısız ama /json/si effects veriyor", None),
    ]:
        MOCK = Mock("control", 1)
        MOCK.eff = mode
        if mode == "si":
            pass
        p, tid = await open_page(cp, "about:blank")
        await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
        check(await p.wait("document.querySelectorAll('#fg .fx').length===20", 15), "20 efekt düğmesi: " + name)
        names = await p.ev("Array.prototype.map.call(document.querySelectorAll('#fg .fx'),function(b){return b.textContent}).join('|')")
        check(names == "|".join(EFFECTS), "efekt sırası/ID eşlemesi korundu: " + mode)
        if expect_hits:
            check(MOCK.eff_hits[:2] == expect_hits, "istek sırası " + str(expect_hits))
        check(await p.wait("document.getElementById('dot').className.includes('on')", 10), "WebSocket canlı: " + mode)
        await p.ev("document.querySelectorAll('#fg .fx')[7].click()")
        check(await _until(lambda: {"seg": [{"id": 0, "fx": 7}]} in MOCK.log), "efekt 7 seçimi komutu: " + mode)
        await close(cp, p, tid)

    # Tüm yollar başarısız: anlamlı hata mesajı + sayfanın geri kalanı çalışır
    MOCK = Mock("control", 1)
    MOCK.eff = "down"
    orig = process_request
    p, tid = await open_page(cp, "about:blank")
    await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
    check(await p.wait("document.getElementById('tt').textContent.includes('Efekt listesi')", 15), "tüm yollar başarısız: hata mesajı gösterildi")
    check(await p.wait("document.getElementById('nm').textContent==='Test LED'", 10), "efekt listesi olmasa da cihaz bilgisi/kontroller yüklendi")
    await close(cp, p, tid)

    print("[palet: panel]")
    MOCK = Mock("control", 2)
    p, tid = await open_page(cp, "about:blank")
    await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
    check(await p.wait("document.querySelectorAll('#fg .fx').length===20"), "palet: sayfa yüklendi")
    check(await p.wait("document.getElementById('dot').className.includes('on')", 10), "palet: WebSocket canlı")
    check("Palet boş" in await p.ev("document.getElementById('pn').textContent"), "palet boşken açıklama (varsayılan renk davranışı)")
    # ekle: + -> 3 kez
    for _ in range(3):
        await p.ev("(function(){var b=document.querySelectorAll('#pl button');b[b.length-1].click()})()")
        await asyncio.sleep(0.15)
    check(await _until(lambda: MOCK.ch[0]["apal"] and len(MOCK.ch[0]["apal"]) == 3), "+ ile 3 renk eklendi (sunucuya apal gitti)")
    check(await p.wait("document.querySelectorAll('#pl button').length===4"), "3 renk + '+' düğmesi")
    check(MOCK.ch[1]["apal"] == [] or len(MOCK.ch[1]["apal"]) == 3, "palet seçili kanallara uygulandı (varsayılan: tüm kanallar)")
    # 5 renge tamamla: + düğmesi kaybolur
    for _ in range(2):
        await p.ev("(function(){var b=document.querySelectorAll('#pl button');b[b.length-1].click()})()")
        await asyncio.sleep(0.15)
    check(await p.wait("document.querySelectorAll('#pl button').length===5"), "5 renkte '+' kalkar (en çok 5)")
    check(await _until(lambda: len(MOCK.ch[0]["apal"]) == 5), "5 renkli palet sunucuda")
    # renk çarkıyla seçili palet rengini değiştir (gerçek dokunma)
    await p.ev("document.querySelectorAll('#pl button')[0].click()")
    await p.ev("document.getElementById('wc').scrollIntoView({block:'center'})")
    await asyncio.sleep(0.2)
    box = await p.ev("(function(){var r=document.getElementById('wc').getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()")
    await mouse(p, box[0] + box[2] * 0.85, box[1] + box[3] * 0.5)   # sağ kenar ≈ kırmızı
    check(await _until(lambda: MOCK.ch[0]["apal"][0][0] > 200 and MOCK.ch[0]["apal"][0][1] < 100), "çark seçili PALET rengini değiştirdi (1. renk kırmızı)")
    check(MOCK.ch[0]["col"][0] == [108, 99, 255], "palet düzenleme normal rengi (col) değiştirmedi")
    check(MOCK.ch[0]["fx"] == 3, "palet düzenleme efekti değiştirmedi (animasyon sürer)")
    # sıralama: 1. rengi sağa taşı
    first = list(MOCK.ch[0]["apal"][0])
    await p.ev("document.getElementById('pR').click()")
    check(await _until(lambda: MOCK.ch[0]["apal"][1] == first), "▶ ile renk sağa taşındı")
    await p.ev("document.getElementById('pL').click()")
    check(await _until(lambda: MOCK.ch[0]["apal"][0] == first), "◀ ile renk sola taşındı")
    # sil
    await p.ev("document.getElementById('pD').click()")
    check(await _until(lambda: len(MOCK.ch[0]["apal"]) == 4), "Sil: 4 renk kaldı")
    # başka istemciden gelen değişiklik: sunucu çerçevesiyle senkron
    MOCK.ch[0]["apal"] = [[255, 0, 0], [0, 255, 0]]
    await broadcast()
    check(await p.wait("document.querySelectorAll('#pl button').length===3"), "başka istemcideki palet panelde senkronlandı (2 renk + '+')")
    # temizle
    await p.ev("document.getElementById('pC').click()")
    check(await _until(lambda: MOCK.ch[0]["apal"] == []), "Temizle: palet boşaldı")
    check("Palet boş" in await p.ev("document.getElementById('pn').textContent"), "temizlenince varsayılan açıklama")
    await close(cp, p, tid)

    print("[renk çarkı işaretçisi]")
    MOCK = Mock("control", 1)
    p, tid = await open_page(cp, "about:blank")
    await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
    check(await p.wait("document.querySelectorAll('#fg .fx').length===20"), "işaretçi: sayfa yüklendi")
    await p.ev("document.getElementById('wc').scrollIntoView({block:'center'})")
    await asyncio.sleep(0.3)
    mk = await p.ev("(function(){var m=document.getElementById('mk'),r=m.getBoundingClientRect(),w=document.getElementById('wc').getBoundingClientRect();return [m.style.left,m.style.top,r.width,w.width,getComputedStyle(m).display,(r.left+r.width/2-w.left)/w.width,(r.top+r.height/2-w.top)/w.height]})()")
    # sayfa açılışında son renk ([108,99,255]: ton ~243°, doygunluk .61) doğru konumda
    check(mk[4] != "none" and mk[2] >= 20, "işaretçi görünür", str(mk[:3]))
    check(abs(mk[5] - 0.362) < 0.03 and abs(mk[6] - 0.228) < 0.03, "açılışta işaretçi son rengin konumunda", f"{mk[5]:.3f},{mk[6]:.3f}")
    # sürükleme: dokunur dokunmaz (sunucu yanıtını beklemeden) işaretçi parmağın altında
    box = await p.ev("(function(){var r=document.getElementById('wc').getBoundingClientRect();return [r.left,r.top,r.width,r.height]})()")
    await p.cmd("Input.dispatchMouseEvent", type="mousePressed", x=box[0] + box[2] * 0.2, y=box[1] + box[3] * 0.5, button="left", clickCount=1, buttons=1)
    await p.cmd("Input.dispatchMouseEvent", type="mouseMoved", x=box[0] + box[2] * 0.75, y=box[1] + box[3] * 0.3, button="left", buttons=1)
    pos = await p.ev("(function(){var m=document.getElementById('mk').getBoundingClientRect(),w=document.getElementById('wc').getBoundingClientRect();return [(m.left+m.width/2-w.left)/w.width,(m.top+m.height/2-w.top)/w.height]})()")
    check(abs(pos[0] - 0.75) < 0.03 and abs(pos[1] - 0.3) < 0.03, "sürüklerken işaretçi parmağı anlık izliyor", f"{pos[0]:.3f},{pos[1]:.3f}")
    await p.cmd("Input.dispatchMouseEvent", type="mouseReleased", x=box[0] + box[2] * 0.75, y=box[1] + box[3] * 0.3, button="left", clickCount=1, buttons=0)
    await asyncio.sleep(0.9)
    # başka istemci rengi değiştirir -> işaretçi taşınır (mavi: [0,0,255] -> ton 240°, doygunluk 1)
    MOCK.ch[0]["col"][0] = [0, 0, 255]
    await broadcast()
    await asyncio.sleep(1.0)
    pos = await p.ev("(function(){var m=document.getElementById('mk').getBoundingClientRect(),w=document.getElementById('wc').getBoundingClientRect();return [(m.left+m.width/2-w.left)/w.width,(m.top+m.height/2-w.top)/w.height]})()")
    check(abs(pos[0] - 0.25) < 0.03 and abs(pos[1] - 0.067) < 0.03, "başka istemciden gelen renkte işaretçi senkronlandı", f"{pos[0]:.3f},{pos[1]:.3f}")
    check(MOCK.ch[0]["fx"] == 3, "renk seçimi efekti değiştirmedi/durdurmadı")
    await close(cp, p, tid)

    print("[Ayarlar: LED sayısı]")
    MOCK = Mock("control", 2)
    p, tid = await open_page(cp, "about:blank")
    await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
    check(await p.wait("document.querySelectorAll('#lc input').length===4", 10), "4 kanal için LED sayısı alanı")
    vals = await p.ev("Array.prototype.map.call(document.querySelectorAll('#lc input'),function(i){return i.value}).join(',')")
    check(vals == "10,20,0,0", "mevcut kayıtlı sayılar gösteriliyor (otomatik 30'a çevrilmedi)", vals)
    check(await p.ev("document.getElementById('lcA').disabled"), "değişiklik yokken Uygula pasif")
    check(await p.ev("!!document.querySelector('#stc a[href=\"/setup\"]')"), "Wi-Fi bağlantısı Ayarlar bölümünde")
    # 4 x 30
    for i in range(4):
        await p.ev("(function(){var e=document.getElementById('ln%d');e.value='30';e.dispatchEvent(new Event('input'))})()" % i)
    check(not await p.ev("document.getElementById('lcA').disabled"), "değer girilince Uygula etkin")
    await p.ev("document.getElementById('lcA').click()")
    check(await _until(lambda: MOCK.cfg_n == [30, 30, 30, 30]), "Uygula: {argb:{leds:[...]}} ile 4 x 30 LED", str(MOCK.cfg_n))
    check(any("argb" in m for m in MOCK.log), "komut WLED uzantısı (argb.leds) üzerinden gitti")
    # geçersiz değer: uyarı + Uygula pasif
    await p.ev("(function(){var e=document.getElementById('ln0');e.value='600';e.dispatchEvent(new Event('input'))})()")
    check(await p.ev("document.getElementById('lcA').disabled") and "0–512" in await p.ev("document.getElementById('lcm').textContent"), "512 üstü: hata mesajı, Uygula pasif")
    await p.ev("(function(){var e=document.getElementById('ln0');e.value='500';e.dispatchEvent(new Event('input'));['ln1','ln2','ln3'].forEach(function(k){var x=document.getElementById(k);x.value='200';x.dispatchEvent(new Event('input'))})})()")
    check("1024" in await p.ev("document.getElementById('lcm').textContent") and await p.ev("document.getElementById('lcA').disabled"), "toplam 1024 sınırı aşılınca engellendi")
    await p.ev("(function(){var e=document.getElementById('ln0');e.value='310';e.dispatchEvent(new Event('input'));['ln1','ln2','ln3'].forEach(function(k){var x=document.getElementById(k);x.value='10';x.dispatchEvent(new Event('input'))})})()")
    check("kare hızı" in await p.ev("document.getElementById('lcm').textContent") and not await p.ev("document.getElementById('lcA').disabled"), "300 üstü: yalnızca uyarı (uygulanabilir)")
    await close(cp, p, tid)

    print("[readonly: palet ve LED sayısı kapalı]")
    MOCK = Mock("readonly", 1)
    p, tid = await open_page(cp, "about:blank")
    await p.cmd("Page.navigate", url=f"http://127.0.0.1:{PORT}/")
    check(await p.wait("document.getElementById('ctl').disabled===true", 10), "readonly: kontroller (palet + ayarlar dahil) devre dışı")
    check(await p.ev("document.getElementById('stc').parentNode.id==='ctl'"), "Ayarlar kartı korumalı fieldset içinde")
    await close(cp, p, tid)

    # Kaynak sırası koruması: /json GET kaydı, /json/* GET kayıtlarından SONRA olmalı
    src = open(os.path.join(HERE, "..", "src", "wled", "wled_compat.cpp"), encoding="utf-8").read()
    pos = {m: src.index('server.on("%s", HTTP_GET' % m) for m in ["/json/state", "/json/info", "/json/si", "/json/eff", "/json/pal", "/json/nodes", "/json"]}
    check(all(pos["/json"] > pos[m] for m in pos if m != "/json"),
          "ESPAsyncWebServer önek eşlemesi: GET /json en son kayıtlı (/json/eff diziyi döndürür)")


async def _until(f, t=4.0):
    end = time.time() + t
    while time.time() < end:
        if f():
            return True
        await asyncio.sleep(0.03)
    return False


# Tüm senaryolardaki komutları topla
ALL_CMDS = []
_orig_apply = Mock.apply


def _rec(self, cmd):
    ALL_CMDS.append(cmd)
    _orig_apply(self, cmd)


Mock.apply = _rec

if __name__ == "__main__":
    asyncio.run(main())
    with open(os.path.join(OUT, "commands.jsonl"), "w", encoding="utf-8") as f:
        for c in ALL_CMDS:
            f.write(json.dumps(c) + "\n")
    print(f"\nSonuc: {passed} gecti, {len(failed)} basarisiz; {len(ALL_CMDS)} komut kaydedildi -> {OUT}")
    for n in failed:
        print("  BASARISIZ:", n)
    sys.exit(1 if failed else 0)
