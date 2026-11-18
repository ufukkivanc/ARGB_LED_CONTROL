#!/usr/bin/env python
"""GERÇEK ESP32 yerel ağ uçtan uca testi: keşif, eşleştirme, REST, WebSocket, LED kontrolü, STA'da tarama.

Kullanım (tek başına):  python lan_e2e_test.py <ip|esp32-argb.local>
  Eşleştirme penceresi açık olmalıdır (BOOT 3 sn). wifi_scan_device_test.py --lan bunu bağlantıdan hemen sonra
  aynı BOOT basışının açtığı pencereyle çağırır.

Adımlar:
  L1. mDNS: esp32-argb.local çözülür (Windows mDNS) ve /api/discover aynı cihazı verir.
  L2. POST /api/pair -> token (token YAZDIRILMAZ, yalnızca bellekte). Token'sız /api/state -> 401.
  L3. REST: /api/info (fw, wifi.mode=sta), /api/state.
  L4. WebSocket /ws: auth -> authOk + state; WS 'set' -> ack + yayın; REST /api/command 'set' -> WS'e state yayını.
  L5. LED: CH1 parlaklığı değiştirilir, REST state ve WS yayını doğrular; özgün değer geri yüklenir.
  L6. STA bağlıyken REST taraması: POST/GET /api/wifi/scan -> done + ağlar, sonrasında wifi hâlâ sta.
  L7. Test token'ı iptal edilir (DELETE /api/auth/tokens/{id}); iptal sonrası 401.
Gereksinim: yalnızca Python 3 standart kütüphanesi. Wi-Fi şifresi kullanılmaz.
"""
import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.error
import urllib.request


class Http:
    def __init__(self, host, token=None):
        self.base = f"http://{host}"
        self.token = token

    def req(self, method, path, body=None, auth=True, timeout=8):
        data = None if body is None else json.dumps(body).encode()
        r = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            r.add_header("Content-Type", "application/json")
        if auth and self.token:
            r.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw) if raw else {}
            except ValueError:
                return e.code, {}


class MiniWs:
    """Standart kütüphaneyle asgari RFC 6455 istemcisi (metin çerçeveleri, ping/pong, close)."""

    def __init__(self, host, path="/ws", timeout=5):
        self.s = socket.create_connection((host, 80), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.s.recv(1024)
            if not chunk:
                raise ConnectionError("handshake kapandı")
            head += chunk
        hdr, self.buf = head.split(b"\r\n\r\n", 1)
        if b" 101 " not in hdr.split(b"\r\n")[0]:
            raise ConnectionError("101 yok: " + hdr.split(b"\r\n")[0].decode(errors="replace"))
        self.closed = None

    def send(self, obj):
        payload = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(payload)
        hdr = bytes([0x81])
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        self.s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _need(self, n, deadline):
        while len(self.buf) < n:
            self.s.settimeout(max(0.05, deadline - time.time()))
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("bağlantı kapandı")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self, timeout=5):
        """Sıradaki metin mesajını (dict) döndürür; zaman aşımında None."""
        deadline = time.time() + timeout
        frag = b""
        try:
            while time.time() < deadline:
                b0, b1 = self._need(2, deadline)
                op, n = b0 & 0x0F, b1 & 0x7F
                if n == 126:
                    n = struct.unpack(">H", self._need(2, deadline))[0]
                elif n == 127:
                    n = struct.unpack(">Q", self._need(8, deadline))[0]
                if b1 & 0x80:
                    self._need(4, deadline)
                data = self._need(n, deadline)
                if op == 0x8:
                    self.closed = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else 1005
                    return None
                if op == 0x9:
                    self.s.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                    continue
                if op in (0x1, 0x0):
                    frag += data
                    if b0 & 0x80:
                        try:
                            return json.loads(frag.decode())
                        except ValueError:
                            frag = b""
        except (socket.timeout, TimeoutError):
            return None
        return None

    def wait(self, pred, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            m = self.recv(timeout=end - time.time())
            if m is None:
                if self.closed is not None:
                    return None
                continue
            if pred(m):
                return m
        return None

    def close(self):
        try:
            self.s.sendall(bytes([0x88, 0x82]) + os.urandom(4) + b"\x00\x00")
        except OSError:
            pass
        self.s.close()


def ch1(state):
    for c in state.get("channels", []):
        if c.get("ch") == 1:
            return c
    return {}


def run(host, check, scan_sta=True):
    """check(cond, name, extra) ile raporlar. Token yalnızca bu fonksiyonun belleğindedir."""
    print(f"\n[L1] Keşif ({host})", flush=True)
    try:
        mdns_ip = socket.gethostbyname("esp32-argb.local")
    except OSError:
        mdns_ip = None
    check(mdns_ip is not None, "mDNS esp32-argb.local çözüldü", mdns_ip or "çözülemedi")
    pub = Http(host)
    st, disc = pub.req("GET", "/api/discover", auth=False)
    check(st == 200 and disc.get("fw") == "0.3.1", "/api/discover yanıtı (fw 0.3.1)", f"{st} fw={disc.get('fw')} mode={disc.get('mode')}")
    check(disc.get("mode") == "sta", "cihaz STA modunda", str(disc.get("mode")))
    if mdns_ip and mdns_ip != host:
        st2, disc2 = Http(mdns_ip).req("GET", "/api/discover", auth=False)
        check(st2 == 200 and disc2.get("deviceId") == disc.get("deviceId"), "mDNS adresi aynı cihaz")

    print("\n[L2] Eşleştirme", flush=True)
    st, unauth = pub.req("GET", "/api/state", auth=False)
    check(st == 401, "token'sız /api/state reddedilir", str(st))
    check(disc.get("pairingOpen") is True, "eşleştirme penceresi açık", str(disc.get("pairingOpen")))
    st, pair = pub.req("POST", "/api/pair", {"clientName": "e2e-test (v0.3.1)"}, auth=False)
    token, token_id = pair.get("token"), pair.get("tokenId")
    check(st == 200 and token and token_id, "POST /api/pair token verdi (token yazdırılmaz)", f"{st} tokenId={token_id}")
    if not token:
        return
    api = Http(host, token)
    try:
        print("\n[L3] REST", flush=True)
        st, info = api.req("GET", "/api/info")
        check(st == 200 and info.get("fw") == "0.3.1", "GET /api/info", f"{st} fw={info.get('fw')}")
        check((info.get("wifi") or {}).get("mode") == "sta", "info.wifi.mode = sta",
              f"rssi={(info.get('wifi') or {}).get('rssi')}")
        st, state = api.req("GET", "/api/state")
        orig = ch1(state)
        check(st == 200 and bool(orig), "GET /api/state (CH1 var)", f"{st} bri={orig.get('brightness')} power={orig.get('power')}")
        orig_bri = orig.get("brightness", 128)

        print("\n[L4-L5] WebSocket + LED kontrolü", flush=True)
        ws = MiniWs(host)
        t0 = time.time()
        ws.send({"v": 1, "type": "auth", "token": token})
        ok = ws.wait(lambda m: m.get("type") in ("authOk", "error"), 5)
        check(ok is not None and ok.get("type") == "authOk", "WS auth -> authOk", f"{(time.time() - t0) * 1000:.0f} ms")
        full = ws.wait(lambda m: m.get("type") == "state", 3)
        check(full is not None and bool(ch1(full)), "WS ilk tam state")

        b1 = 40 if orig_bri != 40 else 60
        ws.send({"v": 1, "type": "set", "id": "e2e1", "ch": 1, "brightness": b1})
        ack = ws.wait(lambda m: m.get("type") in ("ack", "error") and m.get("id") == "e2e1", 3)
        check(ack is not None and ack.get("type") == "ack", "WS set -> ack", str(ack and ack.get("rev")))
        st, s2 = api.req("GET", "/api/state")
        check(ch1(s2).get("brightness") == b1, "REST state WS değişikliğini gösterir", str(ch1(s2).get("brightness")))

        b2 = b1 + 30
        st, r = api.req("POST", "/api/command", {"v": 1, "type": "set", "id": "e2e2", "ch": 1, "brightness": b2})
        check(st in (200, 202), "REST /api/command set", str(st))
        bc = ws.wait(lambda m: m.get("type") == "state" and ch1(m).get("brightness") == b2, 3)
        check(bc is not None, "REST değişikliği WS'e yayınlandı", str(bc and bc.get("rev")))

        ws.send({"v": 1, "type": "set", "id": "e2e3", "ch": 1, "brightness": orig_bri})
        ws.wait(lambda m: m.get("type") == "ack" and m.get("id") == "e2e3", 3)
        st, s3 = api.req("GET", "/api/state")
        check(ch1(s3).get("brightness") == orig_bri, "CH1 parlaklığı geri yüklendi", str(ch1(s3).get("brightness")))
        ws.send({"v": 1, "type": "ping"})
        time.sleep(0.3)
        check(ws.closed is None, "WS açık kaldı")
        ws.close()

        if scan_sta:
            print("\n[L6] STA bağlıyken REST taraması", flush=True)
            t0 = time.time()
            st, _ = api.req("POST", "/api/wifi/scan")
            check(st == 202, "POST /api/wifi/scan -> 202", str(st))
            res = None
            while time.time() - t0 < 50:
                time.sleep(1.0)
                st, res = api.req("GET", "/api/wifi/scan")
                if st == 200 and res.get("status") == "done":
                    break
            nets = (res or {}).get("networks", [])
            check(res is not None and res.get("status") == "done" and not res.get("error"),
                  "STA bağlıyken tarama tamamlandı", f"{time.time() - t0:.1f} sn, {len(nets)} ağ, error={res and res.get('error')}")
            check(len(nets) > 0, "taramada ağ var", str(len(nets)))
            st, ws_ = api.req("GET", "/api/wifi/status")
            check(st == 200 and ws_.get("state") == "connected", "tarama sonrası STA bağlı kaldı", str(ws_.get("state")))
            check("password" not in json.dumps(ws_).lower(), "wifi/status şifre içermez")
    finally:
        print("\n[L7] Test token'ı iptal", flush=True)
        st, _ = api.req("DELETE", f"/api/auth/tokens/{token_id}")
        check(st in (200, 204), "DELETE /api/auth/tokens/{id}", str(st))
        st, _ = api.req("GET", "/api/state")
        check(st in (401, 403), "iptal edilen token reddedilir", str(st))


if __name__ == "__main__":
    passed, failed = 0, []

    def _check(cond, name, extra=""):
        global passed
        suffix = f"  [{extra}]" if extra else ""
        if cond:
            passed += 1
            print(f"  OK   {name}{suffix}", flush=True)
        else:
            failed.append(name)
            print(f"  FAIL {name}{suffix}", flush=True)

    run(sys.argv[1] if len(sys.argv) > 1 else "esp32-argb.local", _check)
    print(f"\nSonuç: {passed} geçti, {len(failed)} başarısız" + (f" -> {failed}" if failed else ""))
    sys.exit(1 if failed else 0)
