#!/usr/bin/env python
"""GERÇEK ESP32 v0.3.2 çoklu kanal testi (yerel ağ): sabit GPIO, bağımsız kanal renk/efekti, çoklu kanal 'set',
WebSocket yayını, NVS kalıcılığı (yeniden başlatma sonrası) ve özgün ayarların geri yüklenmesi.

Kullanım:  python multichannel_device_test.py <ip|esp32-argb.local> [--no-reboot]
  Eşleştirme penceresi açık olmalı (BOOT 3 sn veya uygulamada "Yeni telefon eşleştir"); betik 120 sn bekler.
  Token yazdırılmaz; test sonunda iptal edilir. Kanalların özgün durumu testten önce okunur ve sonda geri yazılır.

Adımlar:
  M1  /api/info: fw 0.3.2, kanal pinleri CH1=18 CH2=19 CH3=22 CH4=23, LED sayıları.
  M2  Bağımsız kanallar: her kanala farklı renk+efekt (tek kanallık 'set'); diğer kanallar değişmez.
  M3  Çoklu kanal: REST set ch:[1,3] color -> CH1/CH3 rengi değişir, efektleri korunur; CH2/CH4 hiç değişmez.
  M4  WebSocket: set ch:[2,4] effect -> ack + yayın; yayında yalnızca CH2/CH4; renkleri korunur.
  M5  Hatalı kanal listesi ([1,5]) reddedilir, hiçbir kanal değişmez.
  M6  NVS: debounce sonrası /api/reboot; yeniden açılışta son durum aynen geri gelir.
  M7  Özgün durum geri yüklenir (renk, 2. renk, efekt, hız, yoğunluk, yön, parlaklık, güç, palet) ve doğrulanır.
  M8  Test token'ı iptal edilir.
"""
import sys
import time

from lan_e2e_test import Http, MiniWs

EXPECT_FW = "0.3.2"
EXPECT_PINS = {1: 18, 2: 19, 3: 22, 4: 23}
FIELDS = ("power", "color", "color2", "effect", "brightness", "speed", "direction", "intensity", "palette")

passed, failed = 0, []


def check(cond, name, extra=""):
    global passed
    if cond:
        passed += 1
        print(f"  ok   {name}" + (f"  [{extra}]" if extra else ""), flush=True)
    else:
        failed.append(name)
        print(f"  FAIL {name}" + (f"  [{extra}]" if extra else ""), flush=True)


def chans(state):
    return {c["ch"]: c for c in state.get("channels", [])}


def view(c):
    return {k: c.get(k) for k in FIELDS}


def get_state(api):
    st, s = api.req("GET", "/api/state")
    return chans(s) if st == 200 else {}


def cmd(api, body):
    body = dict(body)
    body.setdefault("v", 1)
    return api.req("POST", "/api/command", body)


def settle_state(api, pred, timeout=4.0):
    end = time.time() + timeout
    s = {}
    while time.time() < end:
        s = get_state(api)
        if s and pred(s):
            return s
        time.sleep(0.15)
    return s


def wait_online(host, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        try:
            st, d = Http(host).req("GET", "/api/discover", auth=False, timeout=2)
            if st == 200:
                return d
        except OSError:
            pass
        time.sleep(1)
    return None


def main():
    host = next((a for a in sys.argv[1:] if not a.startswith("--")), "esp32-argb.local")
    do_reboot = "--no-reboot" not in sys.argv
    pub = Http(host)

    print(f"[M0] Eşleştirme ({host}) — pencere açık değilse BOOT'a 3 sn basın veya uygulamadan açın", flush=True)
    end = time.time() + 120
    disc = None
    while time.time() < end:
        st, disc = pub.req("GET", "/api/discover", auth=False)
        if st == 200 and disc.get("pairingOpen"):
            break
        time.sleep(1)
    check(disc is not None and disc.get("pairingOpen") is True, "eşleştirme penceresi açık")
    st, pair = pub.req("POST", "/api/pair", {"clientName": "e2e-multichannel (v0.3.2)"}, auth=False)
    token, token_id = pair.get("token"), pair.get("tokenId")
    check(st == 200 and bool(token), "token alındı (yazdırılmaz)", f"tokenId={token_id}")
    if not token:
        return
    api = Http(host, token)
    original = {}
    try:
        print("\n[M1] Sürüm ve kanal yapılandırması", flush=True)
        st, info = api.req("GET", "/api/info")
        check(st == 200 and info.get("fw") == EXPECT_FW, f"fw {EXPECT_FW}", str(info.get("fw")))
        cfg = {c["ch"]: c for c in info.get("channelConfigs", [])}
        pins = {ch: cfg.get(ch, {}).get("gpio") for ch in range(1, 5)}
        check(pins == EXPECT_PINS, "GPIO eşlemesi CH1=18 CH2=19 CH3=22 CH4=23", str(pins))
        check(all(cfg.get(ch, {}).get("enabled") for ch in range(1, 5)), "4 kanal etkin",
              str({ch: (cfg.get(ch, {}).get("enabled"), cfg.get(ch, {}).get("ledCount")) for ch in range(1, 5)}))
        print("    LED sayıları:", {ch: cfg.get(ch, {}).get("ledCount") for ch in range(1, 5)}, flush=True)

        original = get_state(api)
        check(len(original) == 4, "özgün durum okundu (4 kanal)")

        print("\n[M2] Bağımsız kanal renk ve efekti", flush=True)
        plan = {1: ("comet", {"r": 255, "g": 0, "b": 0}), 2: ("breathing", {"r": 0, "g": 255, "b": 0}),
                3: ("rainbow", {"r": 0, "g": 0, "b": 255}), 4: ("twinkle", {"r": 255, "g": 255, "b": 0})}
        for ch, (fx, col) in plan.items():
            before = get_state(api)
            st, _ = cmd(api, {"type": "set", "ch": ch, "effect": fx, "color": col})
            after = settle_state(api, lambda s: s[ch]["effect"] == fx and s[ch]["color"] == col)
            others_same = all(view(after[o]) == view(before[o]) for o in range(1, 5) if o != ch)
            check(st == 202 and after[ch]["effect"] == fx and after[ch]["color"] == col and others_same,
                  f"CH{ch} -> {fx}; diğer kanallar değişmedi")
        s2 = get_state(api)
        check(len({(s2[c]["effect"], tuple(s2[c]["color"].values())) for c in range(1, 5)}) == 4,
              "4 kanal aynı anda farklı renk/efektte")

        print("\n[M3] Çoklu kanal: REST set ch:[1,3] color", flush=True)
        before = get_state(api)
        target = {"r": 10, "g": 200, "b": 180}
        st, _ = cmd(api, {"type": "set", "ch": [1, 3], "color": target})
        after = settle_state(api, lambda s: s[1]["color"] == target and s[3]["color"] == target)
        check(st == 202 and after[1]["color"] == target and after[3]["color"] == target, "CH1 ve CH3 yeni renkte")
        check(after[1]["effect"] == before[1]["effect"] and after[3]["effect"] == before[3]["effect"],
              "CH1/CH3 efektleri korundu (renk değişimi efekti değiştirmez)")
        check(view(after[2]) == view(before[2]) and view(after[4]) == view(before[4]), "seçilmeyen CH2/CH4 hiç değişmedi")

        print("\n[M4] WebSocket: set ch:[2,4] effect", flush=True)
        before = get_state(api)
        ws = MiniWs(host)
        try:
            ws.send({"v": 1, "type": "auth", "token": token})
            ok = ws.wait(lambda m: m.get("type") == "authOk", 5)
            check(ok is not None, "WS authOk")
            ws.wait(lambda m: m.get("type") == "state", 3)
            ws.send({"v": 1, "type": "set", "id": "m4", "ch": [2, 4], "effect": "fire"})
            ack = ws.wait(lambda m: m.get("type") in ("ack", "error") and m.get("id") == "m4", 5)
            check(ack is not None and ack.get("type") == "ack", "WS ack", str(ack and ack.get("type")))
            bc = ws.wait(lambda m: m.get("type") == "state" and m.get("partial"), 3)
            bch = sorted(c["ch"] for c in (bc or {}).get("channels", []))
            check(bch == [2, 4], "yayında yalnızca CH2 ve CH4", str(bch))
        finally:
            ws.close()
        after = settle_state(api, lambda s: s[2]["effect"] == "fire" and s[4]["effect"] == "fire")
        check(after[2]["color"] == before[2]["color"] and after[4]["color"] == before[4]["color"],
              "CH2/CH4 renkleri korundu (efekt değişimi rengi değiştirmez)")
        check(view(after[1]) == view(before[1]) and view(after[3]) == view(before[3]), "CH1/CH3 değişmedi")

        print("\n[M5] Geçersiz kanal listesi", flush=True)
        before = get_state(api)
        st, err = cmd(api, {"type": "set", "ch": [1, 5], "color": {"r": 1, "g": 1, "b": 1}})
        time.sleep(0.5)
        after = get_state(api)
        check(st == 400 and err.get("code") == "invalid_value", "ch:[1,5] reddedildi", f"{st} {err.get('code')}")
        check(all(view(after[c]) == view(before[c]) for c in range(1, 5)), "hiçbir kanal değişmedi")

        if do_reboot:
            print("\n[M6] NVS kalıcılığı (yeniden başlatma)", flush=True)
            expected = {c: view(v) for c, v in get_state(api).items()}
            print("    debounce bekleniyor (12 sn)…", flush=True)
            time.sleep(12)
            st, _ = api.req("POST", "/api/reboot", {})
            check(st in (200, 202), "yeniden başlatma isteği", str(st))
            time.sleep(4)
            d = wait_online(host)
            check(d is not None and d.get("fw") == EXPECT_FW, "cihaz yeniden açıldı", str(d and d.get("uptimeMs")))
            time.sleep(1)
            again = {c: view(v) for c, v in get_state(api).items()}
            diff = [c for c in range(1, 5) if again.get(c) != expected.get(c)]
            check(not diff, "yeniden başlatma sonrası 4 kanalın durumu aynen geri geldi", f"farklı: {diff}" if diff else "")
            st, info = api.req("GET", "/api/info")
            pins = {c["ch"]: c.get("gpio") for c in info.get("channelConfigs", [])}
            check(pins == EXPECT_PINS, "yeniden açılışta pinler sabit", str(pins))
    finally:
        if original:
            print("\n[M7] Özgün ayarlar geri yükleniyor", flush=True)
            for ch, c in original.items():
                body = {"type": "set", "ch": ch}
                body.update({k: c[k] for k in FIELDS if k in c})
                cmd(api, body)
            back = settle_state(api, lambda s: all(view(s[c]) == view(original[c]) for c in original), 6)
            check(all(view(back.get(c, {})) == view(original[c]) for c in original), "özgün durum geri yüklendi")
            print("    NVS yazımı için 12 sn bekleniyor…", flush=True)
            time.sleep(12)
        print("\n[M8] Test token'ı iptal", flush=True)
        st, _ = api.req("DELETE", f"/api/auth/tokens/{token_id}")
        st2, _ = api.req("GET", "/api/state")
        check(st in (200, 204) and st2 == 401, "token iptal edildi; sonrası 401", f"{st}/{st2}")
        print(f"\nSonuç: {passed} geçti, {len(failed)} başarısız" + (f" -> {failed}" if failed else ""), flush=True)


if __name__ == "__main__":
    main()
