# Issue: Effect list does not load in the iPhone control panel

> Draft for a GitHub Issue (the GitHub CLI was not available/authorized in the environment that prepared this file).
> Suggested labels: `bug`, `firmware`, `ios`, `wled-compat`, `control-panel`.

## Summary

On iPhone, the embedded LED control panel (`http://<device-ip>/`, also opened from the WLED app's device detail screen) loads and controls the LEDs
(power, brightness, colour all work), but the **effect list stays empty / does not load**, so no effect can be selected from the panel.

## Environment

- Firmware: this repository at the commit that introduced `firmware/src/wled/control_page.h` (iPhone control panel), WLED access mode `control`.
- Device: ESP32-WROOM-32, GPIO18, 10 × WS2812B; connected to a home Wi-Fi network.
- Client: iPhone, official WLED app (WebView) and/or Safari. *(iOS and Safari versions to be added by the reporter.)*
- Works: Windows Flutter app (full effect control); the panel's JavaScript against a mock WLED server in headless Chrome (iPhone viewport, 42/42 checks incl. all 20 effect buttons).

## Expected behaviour

The "EFEKT" card shows 20 effect buttons (`Solid`, `Rainbow`, … `Music Reactive`) built from `GET /json/eff`; tapping one sends
`{"seg":[{"id":N,"fx":K}]}` and the strip changes effect.

## Actual behaviour

The effect grid is empty / missing on the iPhone. Other cards work. *(Please attach a screenshot and whether a "Efekt listesi alınamadı" toast appeared.)*

## What is known

- Not reproduced off-device: the page logic is covered by `firmware/test_host/browser_ui_test.py` against a mock server, so the cause is probably specific to the real
  firmware responses, request headers sent by iOS, or timing/concurrency on the ESP32.
- The grid is created in the `.then()` of `fetch("/json/eff")` in `control_page.h`; `/json/si` and the WebSocket are started afterwards from the same chain.
  If `/json/eff` fails or returns an unexpected body, the grid stays empty and only a short toast is shown.

## Hypotheses to check (unverified)

1. `GET /json/eff` is rejected by `WledCompat::guard()` for requests from iOS — e.g. per-IP rate limit (20 req/s) hit by the WLED app + WebView together, an unexpected
   `Host` / `Origin` header value, or the mode check (`off` after reboot?). Look at the HTTP status/body of `/json/eff` from the iPhone.
2. Response/timing issue on the ESP32: concurrent requests while the WebSocket upgrade is in progress, or a truncated/empty response from `AsyncWebServer`.
3. iOS WebView `fetch` behaviour (cache, `Content-Security-Policy` `connect-src 'self' ws://<host>` interaction) — compare with Safari.
4. The effect names are fetched before `/json/si`; if the first request fails the page does not retry.

## Suggested debugging steps

- `curl -i http://<ip>/json/eff` from a PC (expected: `200`, JSON array of 20 names) and from the iPhone (Safari: open `http://<ip>/json/eff` directly).
- Check serial monitor output while loading the panel; watch for `429` / `403 bad_host` / `cross_origin_denied`.
- Temporarily add a retry (with backoff) for `/json/eff` and log the failing status in the toast.
- Compare Safari vs the WLED app WebView.

## Acceptance criteria

- The effect grid renders on iPhone (Safari and WLED app WebView) with all 20 effects, and selecting an effect changes the strip.
- If `/json/eff` fails, the page retries and shows the HTTP status in the error message.
- A regression test (browser test with an injected `/json/eff` failure/delay) covers the retry path.

## Notes

This is a known issue recorded at the time of the first public commit; it was intentionally **not** fixed in that snapshot.
