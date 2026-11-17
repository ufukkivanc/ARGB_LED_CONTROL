#!/usr/bin/env python
"""GERÇEK ESP32 üzerinde WLED WebSocket bağlantı sürekliliği testi.

Kullanım:  python ws_soak_test.py [host] [süre_sn]      (varsayılan: esp32-argb.local, 180)
Gereksinim: pip install websockets

Doğrulananlar (WLED erişim modu readonly/control olmalı):
  A. Token'sız WLED istemcisi süre boyunca KESİNTİSİZ açık kalır (5 sn'lik auth timeout'a takılmaz);
     ilk çerçeveyi alır, 'p' kalp atışına 'pong' döner, çerçeveler gelmeye devam eder (control modunda LED komutu denenir ve geri alınır).
  B. Yabancı Origin'li (tarayıcı kaynaklı) istemci muaf DEĞİLDİR: ~5 sn'de 4401 ile kapatılır.
  C. Kendi protokolümüzü (type) konuşup token göndermeyen istemci muaf DEĞİLDİR: ~5 sn'de 4401 ile kapatılır.
  D. Yeniden bağlanma: kapatılıp açılan istemci 2 sn içinde yeni çerçeve alır.
  E. Aynı sürede HTTP /json/info yoklaması hatasız (zaman aşımı/5xx sayılır).
LED durumu test sonunda eski haline getirilir. Token/şifre kullanılmaz.
"""
import asyncio
import json
import sys
import time
import urllib.request

import websockets

HOST = sys.argv[1] if len(sys.argv) > 1 else "esp32-argb.local"
DUR = int(sys.argv[2]) if len(sys.argv) > 2 else 180
passed, failed = 0, []


def check(cond, name, extra=""):
    global passed
    if cond:
        passed += 1
        print("  ok   " + name + (f"  [{extra}]" if extra else ""))
    else:
        failed.append(name)
        print("  FAIL " + name + (f"  [{extra}]" if extra else ""))


def http_get(path):
    t = time.time()
    try:
        r = urllib.request.urlopen(f"http://{HOST}{path}", timeout=5)
        return r.status, json.loads(r.read()), (time.time() - t) * 1000
    except Exception as e:  # noqa: BLE001
        return str(e), None, (time.time() - t) * 1000


async def wled_client(stats):
    """A + D: uzun ömürlü token'sız WLED istemcisi."""
    t0 = time.time()
    async with websockets.connect(f"ws://{HOST}/ws", ping_interval=None, origin=None) as ws:
        first = json.loads(await asyncio.wait_for(ws.recv(), 5))
        stats["first"] = first
        access = first.get("info", {}).get("access")
        stats["access"] = access
        seg0 = first["state"]["seg"][0]
        bri0 = first["state"]["bri"]
        next_p, next_cmd, pongs, frames = t0 + 10, t0 + 3, 0, 1
        end = t0 + DUR
        while time.time() < end:
            now = time.time()
            if now >= next_p:
                await ws.send("p")
                next_p = now + 20
            if now >= next_cmd and access == "control" and not stats.get("cmd_done"):
                stats["cmd_done"] = True
                new = bri0 - 1 if bri0 > 1 else bri0 + 1
                await ws.send(json.dumps({"bri": new}))
                stats["cmd_target"] = new
            try:
                m = await asyncio.wait_for(ws.recv(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            if m == "pong":
                pongs += 1
                continue
            try:
                j = json.loads(m)
            except ValueError:
                continue
            frames += 1
            if "state" in j and stats.get("cmd_target") is not None and j["state"].get("bri") == stats["cmd_target"] and not stats.get("cmd_seen"):
                stats["cmd_seen"] = True
                await ws.send(json.dumps({"bri": bri0}))   # eski değere geri al
                stats["restored"] = True
        stats.update(open_for=time.time() - t0, pongs=pongs, frames=frames, bri0=bri0)
    # D: yeniden bağlanma
    t1 = time.time()
    async with websockets.connect(f"ws://{HOST}/ws", ping_interval=None, origin=None) as ws2:
        await asyncio.wait_for(ws2.recv(), 2)
        stats["reconnect_s"] = time.time() - t1


async def closer(name, headers=None, origin=None, typed=False):
    t0 = time.time()
    try:
        async with websockets.connect(f"ws://{HOST}/ws", ping_interval=None, origin=origin) as ws:
            if typed:
                await ws.send(json.dumps({"v": 1, "type": "ping"}))
            while True:
                await asyncio.wait_for(ws.recv(), 12)
    except websockets.ConnectionClosed as e:
        return e.rcvd.code if e.rcvd else None, time.time() - t0
    except asyncio.TimeoutError:
        return "açık", time.time() - t0
    return None, time.time() - t0


async def http_poll(stats):
    end = time.time() + DUR
    lat, errs, ups = [], 0, []
    while time.time() < end:
        st, j, ms = await asyncio.get_event_loop().run_in_executor(None, http_get, "/json/info")
        if st == 200 and j:
            lat.append(ms)
            ups.append(j.get("uptime", 0))
        else:
            errs += 1
        await asyncio.sleep(5)
    stats.update(http_n=len(lat) + errs, http_err=errs, http_max=max(lat) if lat else 0, uptimes=ups)


async def main():
    print(f"Hedef: {HOST}, süre: {DUR} sn")
    st, info, _ = http_get("/json/info")
    if info is None:
        print("Cihaza ulaşılamadı:", st)
        return 2
    access = info.get("access")
    print("WLED erişim modu:", access)
    if access == "off":
        print("Mod 'off': WLED WS kapalı olmalı; bu test readonly/control gerektirir.")
        return 2
    stats = {}
    results = await asyncio.gather(
        wled_client(stats), http_poll(stats),
        closer("yabancı", origin="http://evil.example.com"),
        closer("typed", typed=True),
        return_exceptions=True)
    print("\n[A] WLED istemcisi")
    if isinstance(results[0], Exception):
        check(False, "WLED WebSocket kesintisiz açık kaldı", repr(results[0])[:90])
    else:
        check(stats["open_for"] >= DUR - 1, f"{DUR} sn boyunca kesintisiz açık", f"{stats['open_for']:.0f} sn")
        check(stats["pongs"] >= max(1, DUR // 20 - 1), "kalp atışı 'p' → 'pong'", f"{stats['pongs']} pong")
        if access == "control":
            check(stats.get("cmd_seen") and stats.get("restored"), "LED komutu (bri) uygulandı, sunucu çerçevesi onayladı ve geri alındı")
        else:
            print("  (readonly: LED komutu denenmedi)")
        check(stats["frames"] >= 1, "durum çerçevesi alındı", f"{stats['frames']} çerçeve")
        check(stats.get("reconnect_s", 99) < 2.0, "[D] yeniden bağlanınca yeni çerçeve < 2 sn", f"{stats.get('reconnect_s', 99):.2f} sn")
    print("[B] yabancı Origin")
    r = results[2]
    check(not isinstance(r, Exception) and r[0] == 4401 and 3.5 <= r[1] <= 8, "yabancı kaynaklı istemci ~5 sn'de 4401 ile kapatıldı", str(r))
    print("[C] type konuşan, token'sız istemci")
    r = results[3]
    check(not isinstance(r, Exception) and r[0] == 4401 and 3.5 <= r[1] <= 8, "token göndermeyen protokol istemcisi ~5 sn'de 4401 ile kapatıldı", str(r))
    print("[E] HTTP yoklaması")
    if isinstance(results[1], Exception):
        check(False, "HTTP yoklaması", repr(results[1]))
    else:
        check(stats["http_err"] == 0, "HTTP /json/info hatasız", f"{stats['http_n']} istek, {stats['http_err']} hata, en yavaş {stats['http_max']:.0f} ms")
        u = stats["uptimes"]
        check(all(b >= a for a, b in zip(u, u[1:])), "uptime geri gitmedi (yeniden başlama yok)", f"{u[0]}→{u[-1]} sn" if u else "")
    print(f"\nSonuç: {passed} geçti, {len(failed)} başarısız")
    for n in failed:
        print("  BAŞARISIZ:", n)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
