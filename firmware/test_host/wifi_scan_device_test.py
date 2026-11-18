#!/usr/bin/env python
"""GERÇEK ESP32 üzerinde USB seri Wi-Fi tarama/kurulum testi (firmware >= 0.3.1).

Kullanım:
  python wifi_scan_device_test.py COM7                       # tarama regresyonu (1-5)
  python wifi_scan_device_test.py COM7 --connect --lan --sta-scan --out rapor.txt
      # uçtan uca: SSID input() ile, şifre getpass ile (ekranda görünmez) EN BAŞTA sorulur;
      # ARGB_TEST_WIFI_PASS ortam değişkeni varsa o kullanılır. Şifre ve SSID hiçbir yere
      # (ekran, rapor, log) yazdırılmaz. --connect modunda 3/4 atlanır (--full ile çalışır).
  --lan     : bağlandıktan sonra lan_e2e_test (mDNS, eşleştirme, REST, WS, LED, STA'da REST taraması)
  --out F   : ekran çıktısının kopyası (sır içermez)

Ön koşul: kurulum penceresi FİZİKSEL olarak açılmalıdır — betik "BOOT bekleniyor" dediğinde
ESP32 üzerindeki BOOT düğmesine 3 sn basılı tutup bırakın. Port DTR/RTS yükseltilmeden açılır (reset yok).

Adımlar:
  1. İlk tarama: scanStarted -> scanResult (scan_busy/scan_failed YOK), süre raporlanır.
  2. Kayıtlı ağ bulunamazken tarama: durum 'failed'/'ap' iken taramanın başarılı olduğu doğrulanır.
  3. Art arda 3 tarama isteği (beklemeden): tek radyo taraması, 2 istek "joined", tam olarak 1 scanResult, hata yok.
     Ardından hemen yeni tarama: yeni sonuç gelir.
  4. STA bağlantı denemesi SÜRERKEN tarama: var olmayan bir ağa wifi komutu -> hemen scan -> scanResult gelir;
     ardından bağlantı 'failed' (not_found) ile sonuçlanır. Kimlik bilgisi NVS'e yazılmaz (yalnızca başarıda yazılır).
  5. Kayıtlı ağ 201 döngüsü yok: bekleme süresince 'Reason: 201' satırı <= 1 (eski sürüm ~2,9 sn'de bir basıyordu).
  6. --connect SSID: taramada SSID görünür -> bağlan -> 'connected' + IP (başarılı bağlantı pencereyi kapatır).
  7. --sta-scan: (6'dan sonra) BOOT'a tekrar basılır, STA bağlıyken tarama yapılır, bağlantı kopmaz.
Gereksinim: Python 3 + pyserial (PlatformIO'nun python'unda hazır).
"""
import getpass
import json
import os
import random
import re
import sys
import threading
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "COM7"
CONNECT = "--connect" in sys.argv
LAN = "--lan" in sys.argv
STA_SCAN = "--sta-scan" in sys.argv
FULL = "--full" in sys.argv or not CONNECT
OUT = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None


class _Tee:
    def __init__(self, *streams):
        self.streams = streams

    def write(self, data):
        for st in self.streams:
            st.write(data)

    def flush(self):
        for st in self.streams:
            st.flush()


def ask_credentials():
    """SSID/şifre yalnızca bellekte tutulur; hiçbir yere yazdırılmaz."""
    ssid = input("Bağlanılacak 2.4 GHz Wi-Fi SSID: ").strip()
    pw = os.environ.get("ARGB_TEST_WIFI_PASS")
    if pw is None:
        pw = getpass.getpass("Wi-Fi şifresi (görünmez; açık ağ için boş): ")
    return ssid, pw

passed, failed = 0, []


def check(cond, name, extra=""):
    global passed
    suffix = f"  [{extra}]" if extra else ""
    if cond:
        passed += 1
        print(f"  OK   {name}{suffix}", flush=True)
    else:
        failed.append(name)
        print(f"  FAIL {name}{suffix}", flush=True)


class Dev:
    """Seri port okuyucu: ARGB: mesajlarını kuyruğa, log satırlarını sayaçlara ayırır."""

    def __init__(self, port):
        self.p = serial.Serial()
        self.p.port, self.p.baudrate, self.p.timeout = port, 115200, 0.1
        self.p.dtr = False
        self.p.rts = False
        self.p.open()
        self.msgs = []
        self.logs = []
        self.lock = threading.Lock()
        self.stop = False
        self.buf = b""
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while not self.stop:
            chunk = self.p.read(512)
            if not chunk:
                continue
            self.buf += chunk
            while b"\n" in self.buf:
                raw, self.buf = self.buf.split(b"\n", 1)
                line = raw.decode(errors="replace").strip()
                if not line:
                    continue
                # Uygulamadaki SerialSetupClient.parseProtocolLine ile aynı: "ARGB:{...}" veya çıplak "{...}"
                m = None
                i = line.find("ARGB:")
                start = i + 5 if i >= 0 else line.find("{")
                if start >= 0:
                    try:
                        m = json.loads(line[start:])
                    except ValueError:
                        m = None
                with self.lock:
                    if isinstance(m, dict) and isinstance(m.get("type"), str):
                        self.msgs.append((time.time(), m))
                    else:
                        self.logs.append((time.time(), line))

    def send(self, obj):
        self.p.write((json.dumps(obj) + "\n").encode())

    def mark(self):
        with self.lock:
            return len(self.msgs), len(self.logs)

    def msgs_since(self, mark):
        with self.lock:
            return [m for _, m in self.msgs[mark[0]:]]

    def logs_since(self, mark):
        with self.lock:
            return [l for _, l in self.logs[mark[1]:]]

    def wait(self, mark, pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            for m in self.msgs_since(mark):
                if pred(m):
                    return m
            time.sleep(0.05)
        return None

    def status(self):
        mk = self.mark()
        self.send({"cmd": "status"})
        return self.wait(mk, lambda m: m["type"] == "status", 2.0)

    def close(self):
        self.stop = True
        time.sleep(0.2)
        self.p.close()


def wait_window(d, label, timeout=600):
    print(f"\n>>> {label}: ESP32 üzerindeki BOOT düğmesine 3 sn basılı tutup BIRAKIN (en çok {timeout} sn bekleniyor)...",
          flush=True)
    end = time.time() + timeout
    while time.time() < end:
        st = d.status()
        if st and st.get("window"):
            print(f"    pencere açık (kalan {st.get('remainingMs', 0) // 1000} sn), durum={st.get('state')}", flush=True)
            return st
        time.sleep(1.0)
    return None


SCAN_LOG = ("Scan start", "Scan done", "Scan attempt", "Scan result", "scanComplete()", "Scan watchdog",
            "Pausing STA", "Scan already running", "Connecting to Wi-Fi", "Connection attempt", "Reason:")


def show_logs(lines):
    """Tarama/bağlantı ile ilgili seri log satırlarını yazdırır (SSID içermezler)."""
    for l in lines:
        if any(k in l for k in SCAN_LOG):
            print(f"      | {l}", flush=True)


def scan_once(d, timeout=50):
    mk = d.mark()
    t0 = time.time()
    d.send({"cmd": "scan"})
    res = d.wait(mk, lambda m: m["type"] in ("scanResult", "error"), timeout)
    return res, time.time() - t0, d.msgs_since(mk), d.logs_since(mk)


def main():
    creds = ask_credentials() if CONNECT else None
    if OUT:
        sys.stdout = _Tee(sys.__stdout__, open(OUT, "w", encoding="utf-8"))
    d = Dev(PORT)
    try:
        st = None
        for _ in range(15):  # port açılınca kart yeniden başlayabilir / tampon boşalır
            st = d.status()
            if st:
                break
        check(st is not None, "cihaz status yanıtı verdi")
        if not st:
            return
        print(f"    fw={st.get('fw')} state={st.get('state')} error={st.get('error')}", flush=True)
        check(st.get("fw", "") >= "0.3.1", "firmware >= 0.3.1", st.get("fw"))

        # 5 (pasif gözlem, pencere beklenirken): 201 döngüsü yok.
        # Açılıştaki meşru 3 deneme sayılmasın: önce bağlantı döngüsünün bitmesi beklenir.
        for _ in range(40):
            if st and st.get("state") != "connecting":
                break
            time.sleep(1.0)
            st = d.status() or st
        mk_idle = d.mark()
        t_idle = time.time()
        st = wait_window(d, "Test 1-4")
        idle_s = time.time() - t_idle
        if not st:
            check(False, "BOOT kurulum penceresi açıldı")
            return
        reasons = [l for l in d.logs_since(mk_idle) if "Reason: 201" in l]
        state_before = st.get("state")
        check(len(reasons) <= 1 or idle_s < 5, "AP'deyken 'Reason: 201' döngüsü yok",
              f"{len(reasons)} satır / {idle_s:.0f} sn")

        # 1 + 2: ilk tarama, kayıtlı ağ bulunamazken
        print("\n[1-2] İlk tarama (durum: %s)" % state_before, flush=True)
        res, dt, msgs, logs = scan_once(d)
        show_logs(logs)
        ok = res is not None and res["type"] == "scanResult"
        nets = res.get("networks", []) if ok else []
        check(ok, "ilk tarama scanResult döndü", f"{dt:.1f} sn, {len(nets)} ağ, yanıt={res and res.get('code', res['type'])}")
        check(not any(m.get("code") == "scan_busy" for m in msgs), "scan_busy üretilmedi")
        check(any(m["type"] == "scanStarted" for m in msgs), "scanStarted ara yanıtı geldi")
        if state_before in ("failed", "ap", "connecting"):
            check(ok, f"kayıtlı ağ yokken (state={state_before}) tarama çalışıyor")

        if not FULL:
            print("\n[3-4b] --connect modu: daha önce doğrulanan regresyon adımları atlandı (--full ile çalışır)", flush=True)
        # 3: art arda istekler
        if FULL:
            regression(d)

        if creds:
            connect_flow(d, creds)
    finally:
        d.close()
        print(f"\nSonuç: {passed} geçti, {len(failed)} başarısız" + (f" -> {failed}" if failed else ""), flush=True)


def regression(d):
    if True:
        print("\n[3] Art arda 3 tarama isteği", flush=True)
        mk = d.mark()
        t0 = time.time()
        for _ in range(3):
            d.send({"cmd": "scan"})
            time.sleep(0.05)
        first = d.wait(mk, lambda m: m["type"] in ("scanResult", "error"), 50)
        time.sleep(3.0)  # fazladan sonuç/hata gelmediğini görmek için
        msgs = d.msgs_since(mk)
        logs = d.logs_since(mk)
        show_logs(logs)
        results = [m for m in msgs if m["type"] == "scanResult"]
        errors = [m for m in msgs if m["type"] == "error"]
        started = [m for m in msgs if m["type"] == "scanStarted"]
        radio = [l for l in logs if "Scan start: attempt 1/" in l]
        check(first is not None and first["type"] == "scanResult", "art arda isteklerde sonuç geldi",
              f"{time.time() - t0:.1f} sn")
        check(len(results) == 1, "tam olarak 1 scanResult", str(len(results)))
        check(len(errors) == 0, "hata yok", ",".join(e.get("code", "?") for e in errors))
        check(len(started) == 3 and sum(1 for m in started if m.get("joined")) == 2,
              "3 scanStarted, 2'si joined", f"{len(started)} / joined={sum(1 for m in started if m.get('joined'))}")
        check(len(radio) == 1, "yalnızca 1 radyo taraması başlatıldı", str(len(radio)))
        print("\n[3b] Tarama sonrası hemen tekrar tarama", flush=True)
        res, dt, msgs, logs = scan_once(d)
        show_logs(logs)
        check(res is not None and res["type"] == "scanResult", "sonuçtan hemen sonra yeni tarama çalışıyor", f"{dt:.1f} sn")

        # 4: STA denemesi sürerken tarama
        print("\n[4] STA bağlantı denemesi sürerken tarama", flush=True)
        bogus = "argb-nonexistent-%04x" % random.randint(0, 0xFFFF)
        mk = d.mark()
        d.send({"cmd": "wifi", "ssid": bogus, "pass": ""})
        acc = d.wait(mk, lambda m: m["type"] in ("wifiAccepted", "error"), 3)
        check(acc is not None and acc["type"] == "wifiAccepted", "test ağı komutu kabul edildi")
        conn = d.wait(mk, lambda m: m["type"] == "event" and m.get("state") == "connecting", 3)
        check(conn is not None, "durum 'connecting'")
        time.sleep(0.5)  # sürücü STA bağlantı taramasının ortasında
        res, dt, msgs, logs = scan_once(d)
        show_logs(logs)
        check(res is not None and res["type"] == "scanResult", "bağlanırken tarama başarılı",
              f"{dt:.1f} sn, yanıt={res and res.get('code', res['type'])}")
        check(any("Pausing STA connection attempt for scan" in l for l in d.logs_since(mk)),
              "STA denemesi tarama için duraklatıldı (log)")
        fail_ev = d.wait(mk, lambda m: m["type"] == "event" and m.get("state") in ("failed", "connected"), 45)
        check(fail_ev is not None and fail_ev.get("state") == "failed", "test ağı 'failed' ile sonuçlandı",
              fail_ev and fail_ev.get("error"))
        check(fail_ev is not None and fail_ev.get("error") == "not_found", "hata kodu not_found",
              fail_ev and fail_ev.get("error"))
        print("      -- bağlantı döngüsü logları --", flush=True)
        show_logs([l for l in d.logs_since(mk) if "Connect" in l or "Reason" in l])
        attempts = [l for l in d.logs_since(mk) if re.search(r"Connection attempt \d of \d failed", l)]
        check(len(attempts) == 3, "tarama duraklatması deneme sayılmadı (tam 3 deneme)", str(len(attempts)))
        st = d.status()
        check(st is not None and st.get("window"), "başarısız bağlantı sonrası pencere açık kalır")

        # 4b: ağ bulunamadıktan sonra (state=failed, error=not_found) tarama
        print("\n[4b] Ağ bulunamadıktan sonra tarama (state=%s, error=%s)" % (st and st.get("state"), st and st.get("error")),
              flush=True)
        res, dt, msgs, logs = scan_once(d)
        show_logs(logs)
        check(res is not None and res["type"] == "scanResult", "not_found sonrası tarama başarılı",
              f"{dt:.1f} sn, {len((res or {}).get('networks', []))} ağ")

        all_logs = d.logs_since((0, 0))
        dones = [l for l in all_logs if "Scan done:" in l]
        fails = [l for l in all_logs if "Scan attempt" in l and "failed" in l]
        wd = [l for l in all_logs if "Scan watchdog" in l]
        early = [l for l in all_logs if "scanComplete()=-2" in l]
        durs = [int(m.group(1)) for l in dones for m in [re.search(r", (\d+) ms,", l)] if m]
        print(f"\n[Özet] SCAN_DONE ile biten: {len(dones)}, başarısız deneme: {len(fails)}, bekçi: {len(wd)}, "
              f"çekirdek erken -2 (yok sayıldı): {len(early)}, süreler (ms): {durs}", flush=True)
        check(len(fails) == 0, "hiçbir tarama denemesi başarısız olmadı", str(len(fails)))
        check(len(wd) == 0, "bekçi hiç tetiklenmedi", str(len(wd)))



def connect_flow(d, creds):
    ssid, pw = creds
    print("\n[6] Tarama sonrası ağ seçimi ve bağlantı (SSID/şifre yazdırılmaz)", flush=True)
    res, dt, _, logs = scan_once(d)
    show_logs(logs)
    names = [n.get("ssid") for n in (res or {}).get("networks", [])]
    check(ssid in names, "hedef ağ tarama listesinde", f"{dt:.1f} sn, {len(names)} ağ")
    st = d.status()
    if not (st and st.get("window")):
        check(False, "bağlanma için pencere hâlâ açık")
        return
    mk = d.mark()
    t0 = time.time()
    d.send({"cmd": "wifi", "ssid": ssid, "pass": pw})
    ev = d.wait(mk, lambda m: m["type"] == "error" or (m["type"] == "event" and m.get("state") in ("failed", "connected")), 60)
    show_logs([l for l in d.logs_since(mk) if "Connect" in l or "Reason" in l or "Provisioning" in l])
    ip = ev.get("ip") if ev else None
    check(ev is not None and ev.get("state") == "connected" and bool(ip), "bağlandı ve DHCP IP aldı",
          f"{time.time() - t0:.1f} sn, ip={ip}" if ip else (ev and (ev.get("error") or ev.get("code"))))
    if not ip:
        return
    st = d.status()
    check(st is not None and not st.get("window"), "başarılı kurulum seri pencereyi kapattı")

    if LAN:
        time.sleep(2.0)  # DHCP sonrası HTTP/mDNS hazır olsun
        import lan_e2e_test
        lan_e2e_test.run(ip, check, scan_sta=True)

    if STA_SCAN:
        st = wait_window(d, "Test 7 (STA bağlıyken SERİ tarama)")
        if not st:
            check(False, "ikinci BOOT penceresi açıldı")
            return
        check(st.get("state") == "connected", "pencere açıkken STA bağlı", str(st.get("state")))
        res, dt, _, logs = scan_once(d)
        show_logs(logs)
        check(res is not None and res["type"] == "scanResult", "STA bağlıyken seri tarama başarılı", f"{dt:.1f} sn")
        check(any("sta=connected" in l for l in logs), "tarama STA bağlıyken yapıldı (log)")
        st = d.status()
        check(st is not None and st.get("state") == "connected", "tarama sonrası STA bağlı kaldı")


if __name__ == "__main__":
    main()
    sys.exit(1 if failed else 0)
