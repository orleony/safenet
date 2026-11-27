# SafeNet development

SafeNet uses Swift and SwiftUI and targets macOS 13+. Building requires the Xcode Command Line Tools with Swift 5.8 or newer.

## Build and verify

Run the commands from the repository root.

```sh
scripts/test.sh        # Core and UI tests. Pass a test name filter as the first argument.
scripts/build.sh       # Bare binary in .build/SafeNetApp. Add --universal for both architectures.
scripts/build-app.sh   # Universal ad-hoc-signed .app, ZIP, checksum and CLI wrapper in dist/.
scripts/verify-app.sh  # End-to-end verification of dist/SafeNet.app with isolated settings.
```

On Apple Silicon with Rosetta, run `SAFENET_TEST_ARCH=x86_64 scripts/test.sh` to test the Intel binaries. See the [verification record](verification.md) for additional checks. Build artifacts in `dist/` are ignored by Git.

## CLI

With SafeNet running, invoke the bundled wrapper or run the app binary directly.

```sh
/Applications/SafeNet.app/Contents/Resources/safenet status
/Applications/SafeNet.app/Contents/MacOS/SafeNetApp version
```

For a shorter command, add `alias safenet=/Applications/SafeNet.app/Contents/Resources/safenet` to your shell configuration. The wrapper also ships as `dist/safenet` in a local build.

| Command | Behavior |
| --- | --- |
| `status` | Show protection status, current IP and frozen apps. |
| `allow [IP\|subnet\|country]` | Allow the current IP or the supplied entry. |
| `pause [90s\|15m\|2h\|restart]` | Pause protection for a duration or until SafeNet restarts. |
| `resume` | Re-enable protection. |
| `close` | Close frozen apps immediately. |
| `panel` | Open the app panel. |
| `config` / `version` | Print the config path or version. |

## Network checks

SafeNet confirms the external address using IP-only services. The enabled providers are configurable with `ip_services`. The periodic check (`check_interval`, 5 seconds by default) uses Cloudflare and ipify while there are protected apps. The full check runs on launch, network change, wake, manual refresh, periodically and when the quick check needs confirmation. A new IP needs `min_agree` matching answers.

Country resolution is separate. SafeNet uses the first valid answer from the GeoIP providers and caches it per IP for 24 hours. IP endpoints that return HTTP 429 or 5xx back off exponentially, from one minute to one hour. GeoIP endpoints use their own cooldown. The on-demand diagnostic shows individual results from the IP services, GeoIP providers, DNS, IPv6 and five AI endpoints.

Automatic route probes run while apps are protected and route checking is enabled. Affected AI apps wait for a fresh route result after a network change. A proxy-only VPN can expose traffic from apps that ignore the system proxy. See the [user guide](../Resources/ПРОЧТИ-МЕНЯ.txt) for limits and configuration.

## Updates and releases

SafeNet checks GitHub Releases for updates daily or on demand. With `updates: notify` (default), the app offers the update. Use `auto` for automatic installation or `off` to disable checks.

The app verifies the Ed25519 signature of `update.json` with its bundled public key, then the archive size and SHA-256. The installer checks the bundle ID, version and code signature. It waits until protection is in its normal state before swapping app bundles and rolls back if the new build fails to confirm launch within 45 seconds.

`VERSION` is the source of the app version. The bundle build number is `major * 10000 + minor * 100 + patch`. After the release changes are merged, the maintainer can publish a version with `scripts/release.sh publish <version>`. The tag triggers the [release workflow](../.github/workflows/release.yml).

For local update testing, `SAFENET_UPDATE_FEED` and `SAFENET_UPDATE_PUBKEY` override the feed URL and Base64 public key. Without a public key, updates are disabled.

## Isolated test mode

- Set `SAFENET_CONFIG_DIR` to a temporary directory to keep the test separate from your settings in `~/Library/Application Support/SafeNet`.
- Set `SAFENET_FAKE_IP=203.0.113.42,NL` to use a simulated check result or `SAFENET_FAKE_OFFLINE=1` to simulate a loss of network.
- Use a disposable process when testing freeze and close. SafeNet uses `SIGSTOP` for freezing and `SIGCONT` before `SIGTERM` for closing. After `close_timeout` it can send `SIGKILL`.
- The watchdog uses the same executable name, `SafeNetApp`. Killing all copies at once can leave processes paused until the next SafeNet launch reconciles its journal.
