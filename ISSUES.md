# Known issues

Everything below is a real, reproducible limitation of the current build — not a wishlist. Each section is mirrored as a GitHub issue with the same title, so the list can be discussed and closed individually.

Status legend: 🔴 broken / misleading · 🟠 works but limited · 🟡 polish

---

## 🔴 [Apple Silicon] Total power falls back to battery rate; charging shows 0.0w

Most Apple Silicon Macs do not expose the SMC key `PSTR` (total system power). The app detects this and falls back to `battery current × voltage`, which is only equal to the system draw **while discharging**. When plugged in, the "total" figure becomes the charge rate, and once the battery is full it reads `0.0w` — the machine is obviously drawing something.

The menu row **功耗来源** says `电池放电速率（本机 SMC 无 PSTR）` in this state, so the number is never silently wrong, but it is still not what the label *整机功耗* promises.

**Possible direction:** read the same Power Telemetry / `IOReport` counters that `powermetrics` uses (needs root or a privileged helper), or average battery drain over a window while charging and subtract the charge rate.

**Not verified on Apple Silicon hardware** — no M-series Mac was available during development.

---

## 🟠 [Desktop Macs] No battery and no `PSTR` → menu bar shows `N/A`

On a Mac mini / Mac Studio / iMac without a battery there is nothing to fall back to. If SMC does not provide `PSTR`, the menu bar shows a grey `N/A` and the floating card shows `未检测到电池`.

**Possible direction:** same `IOReport` path as above; a desktop Mac is exactly the case where a real total-power reading is most useful.

---

## 🟠 First launch is blocked by Gatekeeper

The app is ad-hoc signed (`codesign --sign -`), not notarized. macOS refuses to open it with a plain double-click, and the dialog's *Open* button does not appear on first attempt.

Workaround (documented in the README):

```bash
xattr -dr com.apple.quarantine /Applications/PowerWidget.app
```

**Possible direction:** Developer ID signing + notarization. Requires a paid Apple Developer account; a GitHub Actions release workflow could automate it with repository secrets.

---

## 🟠 Floating panel is invisible over full-screen apps and on other Spaces

The panel is deliberately placed at `desktopIconWindow + 1` so it never covers other windows. The cost: full-screen apps, Mission Control, and other Spaces hide it, and clicking the desktop is the only way to see it again in some setups.

This is by design (the alternative is an always-on-top panel that blocks work), but it surprises people. `⌘P` re-shows it, and an always-on-top mode is the most requested alternative.

---

## 🟠 Panel can end up off-screen after a display change

The panel position is saved in `NSUserDefaults` and restored verbatim. Unplugging an external display, changing resolution, or switching from dual monitors to clamshell can leave the saved origin outside the new `visibleFrame`, so the panel appears to be gone.

**Fix direction:** clamp the restored origin to the current screen's `visibleFrame` on launch.

---

## 🟠 History is capped at 6 hours with no export

`history.json` holds a 3-second-resolution ring buffer covering 6 hours and is flushed to disk once a minute. There is no longer-term aggregation, no CSV/JSON export, and the file has no schema version — a future format change will silently discard existing samples.

---

## 🟡 Samples are raw and unsmoothed

`PSTR` jitters by roughly ±0.5 w between reads, and samples are taken every 1.5 s with no smoothing. The live figure flickers in the last digit and the history curve is visibly hairy. A short moving average (or a median-of-3) would make both calmer without hiding real spikes.

---

## 🟡 No launch-at-login and no crash recovery

The app must be added manually to Login Items, and if it crashes nothing restarts it. A `LaunchAgent` with `KeepAlive` would cover both.

---

## 🟡 UI strings are hard-coded Chinese

Menu items, captions, and the panel labels are Chinese literals in `main.swift`; there is no `Localizable.strings` and no language switch. The config keys and README are English, which makes the project read as half-translated to non-Chinese users.

---

## 🟡 No automated tests, no CI

There is no test target and no GitHub Actions workflow. The Apple Silicon fallback, the desktop (no-battery) path, and the multi-battery summation path have never been executed on real hardware — they are guarded code paths that compile but are unverified. An `xcodebuild`-free CI job could at least build both slices and fail on warnings; a small fixture harness could unit-test `Snapshot` derivations (health, hours left, zone matching) without hardware.

---

## Not an issue, just a note

SMC key names (`PSTR`, `PCPT`, `B0FC`, …) and the `AppleSmartBattery` property names are undocumented Apple internals. They have been stable for years but are not contractual; a macOS major release could rename or remove them. Every read is wrapped so a missing key degrades to `-1` / `N/A` rather than crashing.
