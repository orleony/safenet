# SafeNet

A macOS 13+ menu-bar kill switch: freezes the apps you choose (SIGSTOP) while your external
IP or country is not in your allow list, and closes them if that lasts past the grace period.
User-facing notes (Russian, with a short English part): `Resources/ПРОЧТИ-МЕНЯ.txt`. They are
also copied to `dist/` and into the zip.

## Build

No Xcode or SwiftPM needed; only the Command Line Tools (Swift 5.8+).

```sh
scripts/test.sh                 # core + UI test executables (optional name filter as $1)
scripts/build.sh [--universal]  # bare binary at .build/SafeNetApp
scripts/build-app.sh            # dist/SafeNet.app (universal, ad-hoc signed), dist/safenet,
                                # dist/ПРОЧТИ-МЕНЯ.txt, dist/SafeNet.zip (+ .sha256)
scripts/verify-app.sh           # automated end-to-end check of dist/SafeNet.app (test mode)
```

`dist/` is a build artefact and is not committed. Verification record: `docs/verification.md`.
On Apple Silicon with Rosetta, `SAFENET_TEST_ARCH=x86_64 scripts/test.sh` runs the Intel test binaries.

## Network use and rate limits

Only IP-lookup services and `/cdn-cgi/trace` of five AI hosts are contacted (no telemetry).
Automatic route checks run every 15 seconds while apps are protected. Claude, Claude Code,
ChatGPT, Codex and Perplexity use the trace results for their own services.
After a network change, these apps wait for a fresh route check before resuming.
Settings can enable or disable built-in IPv4 providers (`ip_services` in YAML).
The manual diagnostic still queries all built-in providers for comparison.
When the enabled services return multiple exit IPs but unanimously identify the same country,
an explicit rule allowing that country can pass without confirming a single IP.
IP polling is tiered so free quotas last: the periodic tick (`check_interval`, default 5 s,
only while apps are protected) asks the high-limit services `https://1.1.1.1/cdn-cgi/trace`
(Cloudflare) and `api.country.is` and compares the IP only; the full fan-out (those two plus
ipinfo.io, ipapi.co, ifconfig.co and the IPv6-only v6.ident.me) runs at start, on network
change, on wake, on a manual check, every 10 minutes, and whenever the tick sees another IP or
too few answers. A new IP is never confirmed on fewer than `min_agree` answers. A service that
answers HTTP 429 or 5xx is skipped for 60 s, doubling up to 60 min, reset on success; transport
errors and timeouts never back off; network change, wake and a manual check reset every backoff
(a failure of a request started before the reset is not counted). Skipped services are simply
missing from the answers. The deep check uses its own, unwrapped services. If a VPN routes
1.1.1.1 outside the tunnel the cheap check never matches and every tick runs the full fan-out.

## The `safenet` command

The app binary doubles as the console client: `SafeNet.app/Contents/MacOS/SafeNetApp status`.
For convenience a small wrapper ships in two places: `dist/safenet` (next to the built app) and
`SafeNet.app/Contents/Resources/safenet` (travels with the app). It follows symlinks to find the
app, then falls back to `/Applications/SafeNet.app` and `~/Applications/SafeNet.app`.
Nothing is put on your PATH automatically. To do it yourself, without admin rights (preferred):

```sh
# either an alias
echo 'alias safenet=/Applications/SafeNet.app/Contents/Resources/safenet' >> ~/.zshrc
# or a symlink in ~/bin
mkdir -p ~/bin
ln -s /Applications/SafeNet.app/Contents/Resources/safenet ~/bin/safenet
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc
```

or system-wide, with admin rights:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -s /Applications/SafeNet.app/Contents/Resources/safenet /usr/local/bin/safenet
```

Then, in a new terminal: `safenet status`.

Commands: `status`, `allow [IP | subnet | country]`, `pause [90s | 15m | 2h | restart]`, `resume`,
`close` (closes the frozen apps now), `panel`, `config`, `version`.

The menu can pause protection for a fixed time or until SafeNet restarts.

## Test mode

`SAFENET_FAKE_IP=1.2.3.4,RU` replaces every IP lookup with that answer (window badge
"ТЕСТОВЫЙ РЕЖИМ"); `SAFENET_FAKE_OFFLINE=1` simulates no network; `SAFENET_CONFIG_DIR=<dir>`
uses another settings directory (always set it in test mode so the real
`~/Library/Application Support/SafeNet` is not used).

Test runs leave one preferences file (the panel window frame only): from the bundle
`~/Library/Preferences/local.safenet.app.plist` (`defaults delete local.safenet.app`), from the
bare binary `~/Library/Preferences/SafeNetApp.plist` (`defaults delete SafeNetApp`).

Known limits worth knowing when testing: the watchdog runs the same executable, so
`killall -9 SafeNetApp` kills it too and frozen apps stay stopped until SafeNet is started again
(its start-up reconcile resumes them); closing sends SIGCONT then SIGTERM and lets the app run for
up to `close_timeout` (5 s) before SIGKILL; any `utun` interface (Tailscale too) counts as a tunnel
(affects only the DNS heuristic and the "VPN" label); only one SafeNet instance runs per settings
directory (`safenet.lock`).
