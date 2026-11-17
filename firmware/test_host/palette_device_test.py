#!/usr/bin/env python
"""GERÇEK ESP32 üzerinde palet + kanal başına LED sayısı testi (WLED yolu: tokensiz, `control` modu gerekir).

Kullanım:
  python palette_device_test.py <ip> [--quick] [--save-state dosya.json | --check-state dosya.json]

Adımlar:
  A. LED sayısı senaryoları (10/30/50/150 ve kanal başına farklı): argb.leds ile uygula, info.argb ve seg.len doğrula.
     Yeniden başlatma gerekirse (uyku kanalı canlı etkinleşmediyse) bildirilir ve argb.reboot ile uygulanır.
  B. Her senaryoda 1, 3, 5 renkli palet x 20 efekt: apal + fx gönder, sunucu yankısını doğrula; cihaz yanıt vermeye devam etmeli,
     çalışma süresi geri gitmemeli (çökme/watchdog yok), ölçülen FPS raporlanır.
  C. Kanal başına bağımsız palet.
  D. Başlangıç durumu (LED sayıları, palet, efekt, parlaklık) geri yüklenir.
  --save-state / --check-state: yeniden başlatmadan sonra paletlerin ve LED sayılarının NVS'ten geri geldiğini doğrular.
Gereksinim: yalnızca Python 3 standart kütüphanesi.
"""
import json
import sys
import time
import urllib.request

HOST = sys.argv[1] if len(sys.argv) > 1 else "esp32-argb.local"
QUICK = "--quick" in sys.argv
passed, failed = 0, []
last_uptime = [0]


def check(cond, name, extra=""):
    global passed
    suffix = f"  [{extra}]" if extra else ""
    if cond:
        passed += 1
        print("  ok   " + name + suffix)
    else:
        failed.append(name)
        print("  FAIL " + name + suffix)


def get(path):
    return json.loads(urllib.request.urlopen(f"http://{HOST}{path}", timeout=6).read())


def post(obj):
    obj = dict(obj, v=True)
    req = urllib.request.Request(f"http://{HOST}/json/state", data=json.dumps(obj).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    return json.loads(urllib.request.urlopen(req, timeout=6).read())


def si():
    j = get("/json/si")
    up = j["info"]["uptime"]
    if up + 2 < last_uptime[0]:
        raise RuntimeError(f"CİHAZ YENİDEN BAŞLADI (çökme/watchdog?): uptime {last_uptime[0]} -> {up}")
    last_uptime[0] = up
    return j


def lens(j):
    return [c["n"] for c in j["info"]["argb"]["ch"]]


def wait_lens(target, timeout=6.0):
    end = time.time() + timeout
    while time.time() < end:
        j = si()
        if lens(j) == target:
            return j, False
        time.sleep(0.3)
    j = si()
    pend = [c.get("pn") for c in j["info"]["argb"]["ch"]]
    return j, any(p is not None for p in pend)


def reboot_and_wait():
    try:
        post({"argb": {"reboot": True}})
    except Exception:
        pass
    time.sleep(8)
    for _ in range(40):
        try:
            si_ = get("/json/si")
            last_uptime[0] = si_["info"]["uptime"]
            return
        except Exception:
            time.sleep(2)
    raise RuntimeError("cihaz yeniden başlatıldıktan sonra dönmedi")


PAL = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0], [255, 0, 255]]


def main():
    j = si()
    info = j["info"]
    print(f"Hedef {HOST}; erişim modu: {info['access']}; yazılım {info.get('ver')}; fps {info['leds']['fps']}")
    if info["access"] != "control":
        print("Bu test için WLED erişim modu 'control' olmalı.")
        return 2
    if "argb" not in info:
        print("Bu firmware palet/LED sayısı uzantısını içermiyor (info.argb yok).")
        return 2

    if "--check-state" in sys.argv:
        saved = json.load(open(sys.argv[sys.argv.index("--check-state") + 1]))
        cur = {"lens": lens(j), "apal": [s.get("apal") for s in j["state"]["seg"]]}
        check(cur["lens"] == saved["lens"], "yeniden başlatma sonrası LED sayıları NVS'ten geri geldi", f"{cur['lens']}")
        check(cur["apal"] == saved["apal"], "yeniden başlatma sonrası paletler NVS'ten geri geldi", str(cur["apal"]))
        print(f"\nSonuç: {passed} geçti, {len(failed)} başarısız")
        return 1 if failed else 0

    orig = {"lens": lens(j), "state": j["state"]}
    orig_segs = {s["id"]: s for s in j["state"]["seg"]}
    print("Başlangıç LED sayıları:", orig["lens"])

    scenarios = [("10/30/50/150 karışık", [10, 30, 50, 150]), ("4 x 30 (4 x 1 m)", [30, 30, 30, 30])]
    if not QUICK:
        scenarios += [("4 x 10", [10, 10, 10, 10]), ("4 x 50", [50, 50, 50, 50]), ("4 x 150", [150, 150, 150, 150])]
    fps_table = []

    try:
        for name, target in scenarios:
            print(f"\n[A/B] Senaryo: {name} {target}")
            post({"argb": {"leds": [{"id": i, "n": n} for i, n in enumerate(target)]}})
            jj, pending = wait_lens(target)
            if pending and lens(jj) != target:
                print("  (canlı uygulanamadı; yeniden başlatma gerekli -> argb.reboot)")
                reboot_and_wait()
                jj, _ = wait_lens(target, 10)
            check(lens(jj) == target, "LED sayıları uygulandı", str(lens(jj)))
            segs = jj["state"]["seg"]
            check([s["len"] for s in segs] == [n for n in target if n > 0], "seg.len gerçek kanal uzunluklarını gösteriyor")
            check(jj["info"]["leds"]["count"] == sum(target), "toplam LED sayısı", str(jj["info"]["leds"]["count"]))
            ids = [s["id"] for s in segs]

            for ncol in (1, 3, 5):
                worst_fps = 999
                for fx in range(20):
                    r = post({"seg": [{"id": i, "fx": fx, "apal": PAL[:ncol]} for i in ids]})
                    time.sleep(0.12 if QUICK else 0.3)
                    jj = si()
                    ok = all(s["fx"] == fx and len(s.get("apal", [])) == ncol and s["pal"] == 1 for s in jj["state"]["seg"])
                    if not ok:
                        check(False, f"{name}: palet {ncol} renk, efekt {fx} yankılandı")
                        break
                    worst_fps = min(worst_fps, jj["info"]["leds"]["fps"])
                else:
                    check(True, f"{name}: {ncol} renkli palet x 20 efekt: cihaz yanıt veriyor, yeniden başlama yok", f"en düşük fps {worst_fps}")
                fps_table.append((name, ncol, worst_fps))

        print("\n[C] Kanal başına bağımsız palet")
        jj = si()
        ids = [s["id"] for s in jj["state"]["seg"]]
        if len(ids) >= 2:
            post({"seg": [{"id": ids[0], "apal": PAL[:3]}, {"id": ids[1], "apal": PAL[:5]}]})
            time.sleep(0.5)
            jj = si()
            sg = {s["id"]: s for s in jj["state"]["seg"]}
            check(len(sg[ids[0]]["apal"]) == 3 and len(sg[ids[1]]["apal"]) == 5, "kanal paletleri birbirinden bağımsız")
            post({"seg": [{"id": ids[0], "pal": 0}]})
            time.sleep(0.4)
            sg = {s["id"]: s for s in si()["state"]["seg"]}
            check(sg[ids[0]]["apal"] == [] and len(sg[ids[1]]["apal"]) == 5, "pal:0 yalnızca o kanalın paletini temizler")
        if "--save-state" in sys.argv:
            post({"seg": [{"id": ids[0], "apal": PAL[:3]}]})
            time.sleep(12)   # NVS debounce (<= 10 sn) dolsun
            jj = si()
            json.dump({"lens": lens(jj), "apal": [s.get("apal") for s in jj["state"]["seg"]]},
                      open(sys.argv[sys.argv.index("--save-state") + 1], "w"))
            print("  durum kaydedildi; cihazın gücünü kesip açın ve --check-state ile doğrulayın")
            return 0 if not failed else 1
    finally:
        # D: başlangıç durumunu geri yükle (--save-state kullanılmadıysa)
        if "--save-state" not in sys.argv:
            print("\n[D] Başlangıç durumu geri yükleniyor")
            try:
                post({"argb": {"leds": [{"id": i, "n": n} for i, n in enumerate(orig["lens"])]}})
                wait_lens(orig["lens"])
                for i, s in orig_segs.items():
                    post({"seg": [{"id": i, "fx": s["fx"], "apal": s.get("apal", []), "bri": s["bri"], "on": s["on"],
                                   "col": s["col"][:2]}]})
                time.sleep(0.5)
                check(lens(si()) == orig["lens"], "LED sayıları eski haline döndü", str(orig["lens"]))
            except Exception as e:  # noqa: BLE001
                check(False, "geri yükleme", repr(e))

    print("\nFPS özeti (senaryo, palet renk sayısı, en düşük ölçülen fps):")
    for row in fps_table:
        print("  ", row)
    print(f"\nSonuç: {passed} geçti, {len(failed)} başarısız")
    for n in failed:
        print("  BAŞARISIZ:", n)
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as e:
        print("HATA:", e)
        sys.exit(1)
