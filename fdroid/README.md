# F-Droid

F-Droid metadata is split across two repositories. Knowing which half is which
is most of the confusion.

## fdroiddata, which is not this repo

[fdroiddata](https://gitlab.com/fdroid/fdroiddata) is F-Droid's central metadata
repository on GitLab: one YAML file per app, thousands of them. It holds the
**build recipe** and the facts F-Droid's infrastructure needs (licence, source
URL, signing key, how to build each version). Changing it means opening a merge
request. F-Droid never reads a build recipe out of an app's own repository.

`io.github.jesserockz.littlevideos.yml` here is a **draft of that file**, not a
live one. Nothing in this repo is read by F-Droid, and editing it has no effect
until it is submitted. It is kept here for two reasons: it is what gets pasted
into the merge request, and its `Builds:` recipe is tightly coupled to
`build.sh`, so a change to the toolchain that breaks the recipe is visible in
the same commit that causes it.

Be aware it becomes a stale copy the moment fdroiddata diverges from it. The
version in fdroiddata is always authoritative.

## fastlane metadata, which IS this repo

`fastlane/metadata/android/en-US/` holds the app's title, descriptions,
changelogs and screenshots. F-Droid checks out the latest release, reads that
directory and copies it across **automatically, with no merge request**. It is
also the only way to supply screenshots and a feature graphic.

Changelogs are per versionCode, so `changelogs/10000.txt` is the release note
shown for 1.0.0. Adding `10100.txt` alongside a 1.1.0 release is enough.

Text in the fdroiddata file overrides this directory, which is why `Summary` and
`Description` are deliberately absent there.

Nothing has been put in `images/phoneScreenshots/` yet. `tools/shot.sh <name>`
grabs one from a connected device. An app with no screenshots still publishes,
but F-Droid does not surface it on the Latest tab.

## What this sets up

F-Droid rebuilds the tagged source in its own buildserver and compares the
result byte for byte with the APK attached to the GitHub release. On a match it
publishes **your** signed APK rather than re-signing with F-Droid's key, so a
user can move between a sideloaded build and the F-Droid build without
uninstalling. That is what `Binaries:` plus `AllowedAPKSigningKeys:` mean.

If the rebuild does not match, F-Droid does not publish. There is no partial
credit.

## Before submitting

Licence and signing key are both settled. Apache-2.0, full text in `LICENSE` at
the repo root. `AllowedAPKSigningKeys` holds the SHA-256 of the release
certificate (`CN=Jesse Hills, C=NZ`), read back from a signed APK with:

```sh
apksigner verify --print-certs dist/little-videos-1.0.0.apk \
  | awk '/Signer #1 certificate SHA-256/ {print $NF}'
```

`tools/release-fingerprint.sh <version>` does the whole thing, and prints the
value in the form the metadata wants. Re-run it if the signing key ever changes,
because a mismatch means F-Droid stops accepting updates for the app.

## The one manual step per release

Two things, in two places:

1. **In this repo**, add `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`.
   Picked up automatically, no merge request. Optional, but without it the
   F-Droid listing shows no release note.
2. **In fdroiddata**, add a `Builds:` entry and bump `CurrentVersion` /
   `CurrentVersionCode`. This one needs a merge request.

F-Droid cannot generate the entry itself here. Its `checkupdates` finds new
versions by parsing `AndroidManifest.xml` or `build.gradle` in tagged revisions
for the highest `versionCode`, and this app has a version in neither: `build.sh`
passes it to `aapt2` from the release tag. So `AutoUpdateMode` and
`UpdateCheckMode` are `None` and `Static`, and entries are written by hand.

Each entry is a complete recipe for one version. Copy the previous one and
change four things:

```yaml
  - versionName: 1.1.0        # must match the release tag, minus the v
    versionCode: 10100        # major*10000 + minor*100 + patch
    commit: v1.1.0            # the tag to check out
    output: dist/little-videos-1.1.0.apk
    sudo: [...]               # unchanged
    build:
      - export ANDROID_HOME=$$SDK$$
      - export VERSION_NAME=1.1.0
      - export VERSION_CODE=10100
      - ./build.sh
```

`output` is where F-Droid looks for the APK after `build:` finishes, and it has
to match what `build.sh` actually wrote, which is
`dist/little-videos-$VERSION_NAME.apk`. The `sudo:` block installs the toolchain
the buildserver does not ship by default. `$$SDK$$` is F-Droid's substitution
for the SDK path on the buildserver.

The list only ever grows: old entries stay so F-Droid can rebuild any published
version.

## What makes the build reproducible

`build.sh` pins every input that would otherwise leak into the output:

| Input                                              | How it is pinned                                   |
|:---------------------------------------------------|:---------------------------------------------------|
| Wall clock                                         | `SOURCE_DATE_EPOCH` from the commit date           |
| Timezone                                           | `TZ=UTC`, since zip stores DOS times as local time |
| Locale                                             | `LC_ALL=C`, for stable glob and sort order         |
| dex entry mtimes                                   | `touch` to `SOURCE_DATE_EPOCH` before zipping      |
| zip extra fields                                   | `zip -X`, dropping the Unix timestamp extra field  |
| JDK                                                | Major version 17, verified, build fails otherwise  |
| Android toolchain                                  | build-tools 35.0.0, platform 35                    |

Verified by `tools/verify-reproducible.sh`, which rebuilds an existing
`./build.sh` result under a different wall clock, timezone and locale and diffs
the unsigned and signed APKs. CI runs it on every build.

The checkout path does not affect the output, which matters because F-Droid
builds somewhere else entirely.
