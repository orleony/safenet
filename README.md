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

Commands: `status`, `allow [IP | subnet | country]`, `panel`, `config`, `version`.

## Test mode

`SAFENET_FAKE_IP=1.2.3.4,RU` replaces every IP lookup with that answer (window badge
"ТЕСТОВЫЙ РЕЖИМ"); `SAFENET_FAKE_OFFLINE=1` simulates no network; `SAFENET_CONFIG_DIR=<dir>`
uses another settings directory (always set it in test mode so the real
`~/Library/Application Support/SafeNet` is not used).
