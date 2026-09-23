# Acceptance record — 22 September 2026

## Executed locally

- `node --check`: frontend JS and build scripts parsed.
- `node --test tests/core.test.cjs`: **43/43 passed**. Catalogue, 60 slots, zero seed, validation, consent/refusal separation, GPS metadata constraints, time distinction, aggregate denominators, station/interviewer quantities, CSV/HTML escaping.
- `python tests/browser-smoke.py <practice.html>`: **32/32 passed**. Chromium DOM practice flow, desktop1440 and mobile390/320 widths, candidate visibility and large controls, practice queue simulation and flush, separate refusal, simulated GPS, journal, per-station operators, voiding, viewer locking, role-specific navigation, configuration UI and reset.

**Runner limitation:** this managed Chromium blocks navigation to filesystem/localhost origins. Tests used `set_content()` and the application's explicitly labeled volatile practice fallback. This is not a persistent storage or real offline/PWA test. GPS was stubbed; it was not a hardware-location test. No real political observations were generated or delivered as survey findings.

## NOT executed / launch gates

| Gate | Required evidence before launch | Status |
|---|---|---|
| PostgreSQL installation | 001+002 run on fresh Supabase staging; all RPC calls and SQL assertions pass | NOT RUN |
| Backend RLS and grants | See role/attack cases below | NOT RUN |
| Edge Auth | No token, non-admin token, disabled-admin token all rejected; authorized creation succeeds | NOT RUN |
| Two-device synchronization | Survey from phone A visible in admin B with matching count/timestamp; websocket and 15-second fallback observed | NOT RUN |
| 60-device concurrency | At least 15 accounts/city, simultaneous uploads, repeated UUID replay, delayed bursts, final exact counts reconciled | NOT RUN |
| Restart persistence | Airplane mode, save, close browser, reopen, same user/environment sees pending; no double-count after reconnection | NOT RUN |
| Auth expiry | Expired session refresh/offline capture/re-login behavior; pending not lost and not uploaded as a different user | NOT RUN |
| Android/iPhone | Real touch, Safari/Chrome storage policies, GPS denied/granted/unavailable/stale, screen-lock behavior | NOT RUN |
| Pages workflow | Repo created, source pushed, Pages workflow passes and returns actual URL | NOT RUN |
| Mobile installation | HTTPS, service worker shell+SDK caches, add to home screen, update policy verified | NOT RUN |
| Operational readiness | Verified polling locations, candidate list, staffing, sample protocol, lawful access/diffusion rules | NOT CONFIRMED |
| Recovery and retention | Backup/restore drill, secure CSV destination, retention/deletion policy and device-loss response | NOT RUN |

## Backend negative tests (run in staging, not with real election observations)

1. Anonymous user cannot read responses/profiles/statistics or call administrative RPCs.
2. Viewer cannot query `responses`, `get_records_v2`, account lists, write RPCs or Edge account management. Disabled viewer cannot fetch aggregates. City-scoped viewer sees only that city.
3. Interviewer cannot query other interviewers' records, general dashboard, another station or city. Client edits of profile role, `agent_id`, `district_id`, candidate or station do not override server-owned data.
4. `submit_response` legacy RPC has no execute grant to authenticated/anon. `submit_response_v2` requires active interviewer and validates time, GPS metadata, assigned station, candidate and consent.
5. Same UUID and payload retried returns same ID and exactly one observation; same UUID with changed candidate/time/GPS fails. A UUID owned by another user cannot be replayed as one's own.
6. Attempt direct INSERT/UPDATE/DELETE on base tables as authenticated is denied. All writes use authorized RPCs; even admin UI needs RPCs rather than unrestricted table writes.
7. A record marked void is excluded from aggregates but retained in the journal; own correction expires ten minutes after server receipt. Admin correction remains audited.
8. Opening rejects incomplete catalog, example stations, wrong day or missing 15-per-city assignments. Catalogue/assignment changes are blocked after opening. Eligible pre-close outbox records expire per server close-window rules.
9. GPS values without granted status, out-of-range coordinates, stale timestamps, unknown status and invalid accuracy are rejected. Snapshot location fields come from server stations, not client input.
10. Export endpoints are admin-only and audited. Viewer payload inspection confirms absence of individual survey records and staff GPS (configured polling-site coordinates are not staff GPS).
11. Disable a live user; verify RLS/RPC/Edge checks deny subsequent access even if an old JWT remains unexpired. Check that role changes cannot be obtained through user-editable auth metadata.
12. Confirm Edge origins against actual Pages origin and denial of unauthorized origins. CORS is not used as a substitute for authentication.

A passed DOM check or a hidden button does NOT establish a backend security guarantee. Do not treat the delivered code as an audited or certified election system.
