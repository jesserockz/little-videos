# Little Videos

A local-only video player for a toddler. The feel of YouTube Kids - a grid of big
tappable thumbnails - but it only ever shows video files from one folder you choose,
and it has no way to reach the internet.

## The guarantees

| Property                                                                                  | How it is enforced                                                                        |
|:------------------------------------------------------------------------------------------|:------------------------------------------------------------------------------------------|
| No internet access                                                                        | No `INTERNET` permission in the manifest. The app cannot open a socket.                   |
| No permissions at all                                                                     | The manifest declares zero `<uses-permission>`. `build.sh` fails the build if any appear. |
| No ads, no IAP                                                                            | No third-party code of any kind. No AndroidX, no Play Billing, no analytics.              |
| Never modifies your files                                                                 | There is no delete, rename, move or edit code path anywhere in the app.                   |
| Only your chosen folder                                                                   | Access is a single persisted Storage Access Framework grant to one folder.                |

Storage access uses the system document picker rather than a storage permission, so
the app can read exactly one folder you nominated and nothing else on the device.

## Install

```sh
adb install -r dist/little-videos-1.0.apk
```

Or copy the APK to the phone and open it. Android will ask you to allow installing
from that source, because the APK is self-signed rather than from the Play Store.

## First run

1. Open Little Videos. It shows a "Let us get set up" panel.
2. Tap **Set up**, enter the PIN (**the default is 1234**), and you land in Parent settings.
3. Tap **Video folder** and pick the folder holding the videos, then **Allow**.
4. Press back. The grid fills in.
5. Go back into settings and change the PIN from the default.

Put the videos in a dedicated folder, for example `Movies/Toddler/`. The folder is the
only content filter the app has, so that folder boundary is the safety boundary.

## The parent gate

The gear in the top right needs a **continuous 2 second press**. A tap does nothing, and
so does a short hold. This is deliberate and is not the platform long-press, which fires
at about 500 ms and is well within a toddler's reach. The gear brightens while held so an
adult can see it registering. Sliding a finger off it cancels.

Behind the gate: folder, include subfolders, show titles, what happens when a video ends
(back to the grid / play next / repeat), sort order, grid size, change PIN, rebuild
thumbnails, lock the app, exit, and the screen pinning instructions.

Five wrong PIN entries locks the keypad for 30 seconds.

## Locking the child in

A normal app cannot block the home button, the recent apps screen or the
notification shade, and it cannot get a permission that would let it. Android's
screen pinning can, so the app uses that instead:

- **Back** never leaves the app. On the grid it does nothing.
- **Lock the app** (on by default) makes Little Videos ask Android to pin it every time
  the grid opens. Android shows its own "Pin app?" prompt, so tap Pin. This calls
  `startLockTask()`, which needs no permission. While pinned, home, recents and the
  notification shade are all disabled.
- **Exit Little Videos**, behind the parent gate, unpins and closes the app.

Pinning on its own can still be undone by holding back and overview together (or the
gesture navigation equivalent), which toddlers find by accident surprisingly fast. So in
the device's Settings > Security and privacy > More security settings > App pinning,
**turn on "Ask for PIN before unpinning"**. With it on, unpinning, including through
Exit, goes to the lock screen.

If the prompt is dismissed, the app asks again the next time the grid opens. Once you
have unpinned it, through Exit or the system gesture, it does not ask again until you
leave the app with home or recents and come back. Turn
**Lock the app** off if you would rather pin by hand from the app switcher.

Verified on Android 13: the folder picker still opens while the app is pinned, so you do
not need to unpin to change the video folder.

## Supported files

Anything the device can decode. Tested with MP4 (H.264), MKV and WebM (VP9). Files whose
provider reports a generic MIME type are matched on extension instead: mp4, mkv, webm,
m4v, mov, avi, 3gp, 3g2, ts, m2ts, mts, mpg, mpeg, mpe, ogv, flv, wmv, asf, divx.

Subfolders are included by default, capped at 8 levels deep and 2000 files.

## Building

Needs the Android SDK (platform 35, build-tools 35.0.0) and JDK 21. No Gradle,
no network access, no dependency resolution.

```sh
./build.sh
```

Output lands in `dist/`. The script creates `keystore/little-videos.jks` on first run
and reuses it afterwards, so later builds install over the top as an update. That
keystore password is `littlevideos`. It is a throwaway sideload key, not a secret, but
keep the file if you want to keep updating the same install.

`tools/smoke-test.sh` installs onto a connected device, launches the app, screenshots it
and reports crashes. `tools/shot.sh <name>` grabs a screenshot.
`tools/release-fingerprint.sh <version> [keystore]` builds a signed release APK with the
real key and prints the signing certificate fingerprint F-Droid needs.

### Debug build

`BUILD_VARIANT=debug ./build.sh` writes `dist/debug/little-videos-<version>-debug.apk`
with the package `io.github.jesserockz.littlevideos.debug`, so it installs alongside the
real app. It is debuggable and labelled "Little Videos Debug". Pull request builds upload
it as an artifact.

### Build-time overrides

`build.sh` takes its signing material and version from the environment, so the same
script serves a local sideload build and a CI release build.

| Variable                              | Default                               | What it does                          |
|:--------------------------------------|:--------------------------------------|:--------------------------------------|
| `ANDROID_KEYSTORE`                    | `keystore/little-videos.jks`          | Keystore to sign with                 |
| `ANDROID_KEYSTORE_PASSWORD`           | `littlevideos`                        | Store password, also the key password |
| `ANDROID_KEY_ALIAS`                   | `littlevideos`                        | Alias of the key in the keystore      |
| `VERSION_NAME`                        | `1.0`                                 | versionName and the `dist/` filename  |
| `VERSION_CODE`                        | `1`                                   | versionCode                           |
| `ALLOW_GENERATED_KEY`                 | unset                                 | In CI, opt in to a disposable key     |
| `JDK_VERSION`                         | `21`                                  | Required JDK major version            |
| `SOURCE_DATE_EPOCH`                   | commit date                           | Timestamp baked into the APK          |

Two rules keep the two apart. With `CI` set and no keystore at `ANDROID_KEYSTORE`,
`build.sh` refuses to run rather than quietly minting a throwaway key, because an APK
signed with the wrong key cannot install over an existing one. Locally, with `CI`
unset, it still generates the key on first run as it always has.

In CI the keystore comes from the `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD` and `ANDROID_KEY_ALIAS` repository secrets. The Build
workflow uses them, and so does the Release workflow, which rebuilds the commit it
is about to tag and so needs the same key to reproduce the signed APK. Both call the
same composite action, `.github/actions/android-build`, which sets up the toolchain
and runs `./build.sh` then `tools/verify-reproducible.sh`, so there is one build path to keep honest.

The GitHub release APK is signed with a different key from the one `build.sh` makes
locally, so a locally built install has to be uninstalled before a release APK will
install over it, and vice versa.

### Reproducible builds

The APK is bit-for-bit reproducible: the same commit built on a different day,
in a different timezone, under a different locale, from a different directory
produces an identical file. That is what lets F-Droid rebuild a release, compare
it against the published APK and then ship the developer-signed one rather than
re-signing it.

```sh
./build.sh && ./tools/verify-reproducible.sh
```

builds, then rebuilds with the clock, timezone and locale moved and diffs the
unsigned and signed APKs. CI runs it on every build, so a regression fails the PR rather than
surfacing as an F-Droid verification failure months later.

The one input that is not self-correcting is the JDK. javac majors emit
different bytecode from these sources, so `build.sh` requires JDK 21 and fails
rather than quietly using another. Changing `JDK_VERSION`, the build-tools
version or the compile SDK changes the output hash and needs a matching update to
`fdroid/io.github.jesserockz.littlevideos.yml`. `tools/fdroid-add-build.sh` takes
the JDK for a new entry from the released commit's `build.sh`.


### Opening it in Android Studio

The project is laid out the way Gradle expects, but there are no Gradle files, because
`aapt2` requires the `package` attribute in `AndroidManifest.xml` while AGP 8 rejects it.
To convert: delete `package="io.github.jesserockz.littlevideos"` from the manifest and set
`namespace = "io.github.jesserockz.littlevideos"` in the module's `build.gradle.kts` instead.
`build.sh` will stop working once you do that.

## Layout

```
app/src/main/AndroidManifest.xml   zero permissions, four activities
app/src/main/java/.../
  GridActivity      child-facing grid, the launcher activity, the gear gate
  PlayerActivity    fullscreen playback, big overlay controls, no seek bar
  PinActivity       4 digit parent gate with lockout
  SettingsActivity  parent settings
  VideoLibrary      SAF folder enumeration via DocumentsContract
  ThumbnailLoader   memory + disk thumbnail cache, duration extraction
  VideoItem, Prefs, Ui
build.sh                           the whole build, about 200 lines
```

## Releasing

Releases are automatic apart from one button. Merge PRs, then run the Release
workflow.

1. **Merge a labelled PR.** The label decides the version bump, so an
   unlabelled PR is a patch. `.github/labels.yml` lists them and
   `tools/sync-labels.sh` applies them to the repo.
2. **Release Drafter** runs on the push. It updates the draft release, always
   writes `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` from
   the draft body and commits it, clears any APK from the previous drafted
   version, and records the resulting commit for the build. Pushing to main
   regenerates the draft body, so it overwrites any manual edits to the draft.
3. **Build** runs next, chained off the drafter rather than racing it. It
   checks out the commit the drafter recorded, builds twice to prove the
   output is reproducible, attaches the APK to the draft, pins the release to
   that commit and removes the "do not publish" caution.
4. **Run the Release workflow** when you want to ship. It refuses to publish a
   draft that has no assets, still carries the caution, is not pinned to a
   commit, or has no APK matching the tag. If you edited the draft body by
   hand, Release rewrites the changelog to match it, commits that with the
   built commit's date so the APK stays reproducible, and tags that commit
   (the change is also pushed to main). Before anything is pushed it rebuilds
   the exact commit it is about to tag and refuses to publish unless the result
   is byte-identical to the APK attached to the draft: the same check F-Droid
   will run against the tag, done up front, on every release. Then it
   publishes by release id, which creates the tag.

The version lives only in the release tag. Nothing in the source tree carries
a version number, and `build.sh` is handed one by CI.

The first release is a special case: with nothing published, Release Drafter
counts up from 0.0.0, so the drafter workflow forces the initial version once
and then steps out of the way. There are no merged PRs to summarise, so write
its notes by editing the draft before running Release.

## Licence

Apache License 2.0. The full text is in [LICENSE](LICENSE).

Copyright 2026 Jesse Hills.

## Deliberate omissions

There is no seek bar in the player, only a thin non-interactive progress line. A toddler
scrubbing a video is worse than no seeking at all. Cards have no long-press behaviour, so
there is nothing to trigger by accident.
