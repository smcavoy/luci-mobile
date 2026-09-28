# Feasibility: unavailable routers, router selector, client Wi-Fi stats

Status: proposal. Based on `main` at v2.0.0 (`b617fca`).

## Summary

| Goal | What exists today | Feasible? | Effort |
| --- | --- | --- | --- |
| Handle unavailable routers gracefully | Unreachability is detected (`isRouterUnreachable`), but it is shown as a login failure, and a router that is down at launch leaves you stuck on the login form | Yes, app-only | Medium |
| Router selector | Saved profiles, a selector sheet on the Dashboard, and a Manage Routers screen | Yes, app-only | Small–medium |
| Wi-Fi stats for a client | Client detail already shows signal, SNR, PHY rates and traffic from `iwinfo.assoclist`, for the selected router only | Yes. The basics need no new packages. Richer stats need router packages and ACLs that vary by platform | Small (basics) to large (full) |

No new Flutter dependencies are needed for any of this. The only new
requirements are optional packages on the router.

## 1. What the code does today

### Multiple routers

- `Router` (`lib/models/router.dart`) is a saved profile with a primary
  address and an optional fallback address. Profiles are kept in secure
  storage through `RouterService`.
- `AppState.selectRouter()` bumps `_sessionToken`, clears router-scoped state
  and logs in with `loginWithFallback`. `RouterSession`
  (`lib/state/router_session.dart`) has value equality, so Riverpod providers
  that watch it are invalidated when the router changes.
- There are two selector entry points:
  - A bottom sheet on the Dashboard (`dashboard_screen.dart` ~L1448).
  - The Manage Routers screen (`manage_routers_screen.dart`).
- The Clients tab can combine every saved router
  (`fetchAggregatedClients`). It logs in to each router in parallel on every
  fetch, and a router that fails is silently left out. The fetch only throws
  when all routers fail.

### Unavailable routers: where it falls short

1. **Unreachable is reported as "login failed".** When `selectRouter()` fails
   it always sets `AppFailure(AppFailureKind.login)`, whether the password was
   refused or nothing answered. `isRouterUnreachable()` already tells these
   apart. So far only the event feed and the reboot/apply paths use it.
2. **A router that is down at launch blocks the others.** The splash screen
   goes to `/login`, and `tryAutoLogin` retries the last credentials. If that
   router does not answer, the user gets the manual login form. It does not
   list the other saved routers.
3. **Selection is all-or-nothing.** Picking a router that is down clears the
   dashboard and shows an error. Nothing tells you beforehand that it is down,
   and nothing retries on its own.
4. **Partial failure is hidden in the combined client list.** When a router
   fails it contributes no clients, and the UI does not say which router is
   missing.
5. **Slow failures.** Dio times out after 10 s to connect and 15 s to receive
   (`http_client_manager.dart`). With a fallback address that adds up to
   about 20–30 s before a dead router is reported.

### Client Wi-Fi stats

- `StationInfo` (`lib/models/station_info.dart`) parses `iwinfo.assoclist`:
  signal, noise/SNR, inactive time, connected time, rx/tx rate, MHz, MCS,
  bytes and packets.
- `ClientDetailLoader` (`client_detail_notifier.dart`) fetches it once when
  the page opens, through the **selected** router's session. It shows a Signal
  card and a Traffic card, and degrades on its own
  (`stationUnavailable`).
- Gaps:
  - A client from another router in the combined list gets no station stats,
    because the lookup uses the selected router.
  - The stats are a single snapshot. There is no live refresh and no history.
  - There are no roaming or band-steering details, retries or airtime.
  - The client list shows no signal.

## 2. Proposal: graceful handling of unavailable routers

App-only changes. No router packages.

### 2.1 Per-router reachability state

Add a small `RouterHealth` model keyed by router id:
`unknown | checking | online | unreachable | authFailed`, plus
`lastSeen` and `lastError`. Fill it from:

- `RouterLivenessProbe.isReachable()`. This already exists, needs no
  credentials, and times out after 5 s. Probe every saved router when the app
  starts, when the selector opens, and when the app resumes. Probe both
  addresses when a fallback is set.
- Real results from `login()`, `fetchDashboardData()` and the aggregated
  fetches. Classify them with `isRouterUnreachable()` versus an RPC or auth
  error.

Keep it in a Riverpod `NotifierProvider<Map<String, RouterHealth>>`, next to
`sessionProvider`. Do not add it to `AppState`, which is already 3.4k lines.
The newer code (`feature_providers.dart`, `RouterSession`) points this way.

### 2.2 Distinguish failure kinds

Add `AppFailureKind.unreachable` to `app_failure.dart`. In `selectRouter()`
and `login()`, map `isRouterUnreachable(cause)` to it. Then the screen can
offer **Retry**, **Switch router** or **Try fallback address**, rather than
"check your password". This adds l10n strings. All 14 ARB files must stay
key-complete, which `arb_completeness_test.dart` enforces.

### 2.3 Launch when the last router is down

In `LoginScreen._tryAutoLogin()`, if auto-login fails as *unreachable* and
other routers are saved:

- Show a "Couldn't reach <name>" state that lists the saved routers with
  their health. Tapping one calls `selectRouter()`.
- Optionally, add a preference to auto-select the first reachable router.

Keep the manual login form available as a secondary action.

### 2.4 Combined clients

Have `fetchAggregatedClients` return per-router outcomes alongside the list.
Show a dismissible banner such as "2 of 3 routers answered · Office AP
unreachable". Reuse one session per router rather than logging in on every
fetch. That is a separate optimisation, but it lowers rpcd load and makes
timeouts rarer.

### 2.5 Timeouts

Use a short connect timeout (3–5 s) for the *first* request to a router whose
health is `unreachable` or `unknown`. Keep the current values for
established sessions. Always probe first rather than attempting a full login
against a router already known to be down.

### Risks

- **Session-token discipline.** All new async paths must respect
  `_sessionToken` and the `RouterSession` invalidation, or stale health
  results will land on the wrong router. Existing tests show the pattern:
  `clients_router_switch_test.dart` and `router_session_test.dart`.
- **Apply critical section.** No health probe may trigger a re-login while a
  `uci.apply`/`uci.confirm` is in flight (`apply_lock.dart`).
- **Background isolate.** `background_monitor.dart` polls one router. It is
  out of scope here, but should not be broken by the changes.

## 3. Proposal: router selector

The selector exists. The work is to make it always reachable and
health-aware.

- **Promote it to the app bar.** `LuciAppBar` would show the current router's
  name with a dropdown chevron on every tab. Tapping it opens the existing
  sheet, extracted from `dashboard_screen.dart` into a reusable widget such as
  `lib/widgets/luci_router_switcher.dart`.
- **Show health in each row:** a status dot (online / unreachable / auth
  failed / checking) and "last seen 5 min ago". Probe when the sheet opens.
- **Allow selecting an unreachable router** and land on a clear "unreachable"
  state (§2.2), rather than blocking the choice. The user may be about to
  join its network or VPN.
- **Optional extras:** a user-set display name per profile, since today it
  uses `lastKnownHostname` or the IP, and manual ordering. Both need a
  backward-compatible `Router.toJson` change: new optional keys that are left
  out when null, matching how `alternateAddress` is handled.

Effort: small to medium, mostly UI and l10n.

## 4. Proposal: client Wi-Fi stats

"Client" could mean either of two things. Both are covered.

### 4.1 Stats for a device connected to the router (main case)

Data sources, from least to most demanding:

| Tier | Source | Router needs | Gives | Notes |
| --- | --- | --- | --- | --- |
| 0 | `iwinfo.assoclist` (used today) | `rpcd-mod-iwinfo` (already required) | signal, noise, SNR, rx/tx rate, MHz, MCS, VHT/HE flags, bytes, packets, connected and inactive time | Works on mac80211 drivers: ath9k/10k/11k, mt76, iwlwifi. Limited on Broadcom `wl` and some vendor SDK drivers |
| 1 | `iwinfo.info` / `luci-rpc.getWirelessDevices` (used today) | — | the AP side: channel, band, tx power, noise floor, HT/VHT/HE mode | Gives context for the client's link |
| 2 | `hostapd.<iface>` ubus (`get_clients`) | hostapd built with ubus (default), plus an rpcd ACL grant for `hostapd.*` `get_clients` | per-station flags (authorized, WMM, HT/VHT/HE), 802.11k/v capability, AID, signal | The default LuCI ACLs may not grant `get_clients`. **Must be verified on 23.05, 24.10 and 25.12.** Otherwise the user needs an ACL file under `/usr/share/rpcd/acl.d/` |
| 3 | `iw dev <if> station dump` via `file.exec` | the `iw` package (`iw-full` for some fields) and an ACL granting exec on `/usr/sbin/iw` | tx retries/failed, beacon loss, per-chain signal, avg signal, expected throughput, airtime | `file.exec` is granted per exact command path (measured in #80). This is the most detailed source and needs the most user setup. Output is text and must be parsed |
| 4 | History: `luci-app-statistics` + `collectd-mod-iwinfo`, or polling on the phone | collectd (optional) | signal and rate over time | collectd stores RRD files on the router, which are awkward to read over RPC. Polling tier 0 on the phone while the page is open is simpler |

**Vendor differences**

- **GL.iNet:** `glinet_api_service.dart` already adds data. GL.iNet firmware
  keeps the ubus `iwinfo` object, so tier 0 works. Its own API may offer
  client signal. Check before adding code for it.
- **Broadcom / proprietary drivers** (some Asus, Netgear ports): `iwinfo`
  may return empty or partial assoclists. The UI must degrade per field,
  which `StationInfo` already does because every field is nullable.
- **Mesh / WDS / 802.11s:** stations appear on mesh or WDS interfaces. Filter
  by interface mode so peer APs are not shown as clients.
- **Multi-AP setups (dumb APs):** a client is on whichever AP it is
  associated with. The DHCP owner is often the main router, which does not
  see it. See §4.3.

**How missing packages are handled.** The existing `CapabilityService` and
`RouterCapabilities` already probe features at runtime and turn a missing
package or permission into a named reason. Add
`RouterFeature.hostapdClients` and `RouterFeature.iwStationDump`, so the UI
can say "Install `iw` and grant access for retry and airtime stats" instead
of hiding the section. Document the optional packages in the README's
*Router setup* section.

### 4.2 Stats for the phone itself (optional)

This means the phone's own link to the router.

- **Android:** `WifiManager.getConnectionInfo()` / `WifiInfo` gives RSSI,
  link speed, frequency and BSSID. It needs location permission for SSID and
  BSSID, which the app does not request today. It requires a platform channel
  or a plugin such as `network_info_plus`. `network_info_plus` gives
  SSID/BSSID/IP only, not RSSI, so a small custom channel is needed.
- **iOS:** very restricted. There is no public RSSI API.
  `NEHotspotNetwork.fetchCurrent` gives SSID/BSSID and a mostly-zero
  `signalStrength`, and needs the *Access Wi-Fi Information* entitlement and
  location permission.

For most purposes it is easier to find the phone's own MAC in the router's
assoclist and reuse §4.1. This also works on iOS, with the caveat that
private/random MACs are per-SSID but stable, so matching by current IP is
more reliable. This is feasible, but the per-platform cost and the privacy
permissions make it a poor first step. I recommend deferring it.

### 4.3 Planned enhancements, in order

1. **Look up stats on the owning router.** `ClientDetailLoader` should query
   the router in `client.routerId`, not the selected one. The aggregated fetch
   already logs in to each router. A read-only `RouterSession` for a
   non-selected router is enough for assoclist.
   `_isOwnedBySelectedRouter` still gates *writes*.
2. **Find the AP that serves the client.** When the DHCP owner does not see
   the MAC in its assoclist, query the other saved routers (the dumb-AP case).
   Show "Connected via Office AP · 5 GHz".
3. **Live refresh.** While client detail is open, poll tier 0 every 2–5 s.
   Show a signal sparkline with the existing `fl_chart` dependency, kept in
   memory only. Pause when the app is in the background.
4. **Signal in the client list.** Each row gets signal bars from the assoclist
   data the combined fetch already downloads. Today it keeps only MACs
   (`fetchAllAssociatedWirelessMacsAggregated`).
5. **Tiers 2 and 3** behind capability gates, after checking ACL defaults on
   real OpenWrt releases.

Effort: steps 1, 3 and 4 are small to medium. Step 2 is medium. Step 5 is
medium to large and mostly router-side validation.

## 5. Upstream guidelines to follow

These come from `CONTRIBUTING.md`, `analysis_options.yaml`, CI and the
conventions in #80.

- **CI must pass:** `dart format --set-exit-if-changed .`,
  `flutter analyze --fatal-infos` (lowerCamelCase constants and no
  SCREAMING_SNAKE_CASE) and `flutter test`. CI uses Flutter 3.47.1.
- **Conventional commits:** `feat:`, `fix:`, `docs:`, and so on.
- **Keep PRs small and focused.** Suggested split:
  1. `feat: per-router health and unreachable failure kind` (§2.1–2.2)
  2. `feat: launch fallback when the last router is unreachable` (§2.3)
  3. `feat: health-aware router switcher in the app bar` (§3)
  4. `feat: partial-failure banner for aggregated clients` (§2.4)
  5. `feat: client Wi-Fi stats from the owning router, live refresh` (§4.3 1–3)
  6. `feat: signal in client list` (§4.3 4)
  7. `feat: hostapd / iw station stats behind capability gates` (§4.3 5)
- **Tests for new behaviour.** Put unit tests next to the existing ones:
  `router_unreachable_test`, `clients_router_switch_test`,
  `capability_service_test` and `client_detail_providers_test`. Add mock data
  under `assets/mock/` so reviewer mode keeps working. That mode is used for
  App Store review, so new screens must render from mocks.
- **Localization.** Every new string goes into all 14 ARB files.
  `arb_completeness_test` fails otherwise.
- **Runtime capability probing, not assumptions.** Features that need router
  packages or permissions go through `CapabilityService` and show a named
  reason when unavailable.
- **Measure against real firmware.** #80 changed code after measuring rpcd
  behaviour on OpenWrt 24.10.4. The hostapd and `file.exec` ACL assumptions in
  §4.1 need the same check before tiers 2 and 3 ship.
- **Backward-compatible storage.** New `Router` JSON keys must be optional,
  so profiles saved by 2.0.0 still load.
- **Privacy.** No analytics. Any history stays on the device. Do not request
  phone location permission unless §4.2 is taken on.
- **Docs.** Update the README feature list and *Router setup* section when
  optional router packages become useful.

## 6. Open questions

1. When the last router is down at launch, should the app auto-select the
   first reachable one, or always ask?
2. Are your extra routers full routers with their own DHCP, or dumb APs
   behind one DHCP server? This decides how important §4.3 step 2 is.
3. Which OpenWrt versions and hardware (driver families) do you need to
   support? This decides whether tiers 2 and 3 are worth it.
4. Is §4.2 (the phone's own Wi-Fi stats) wanted, or is router-side data
   enough?
