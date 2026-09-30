# Little Videos

A local-only video player for a toddler. The feel of YouTube Kids - a grid of big
tappable thumbnails - but it only ever shows video files from one folder you choose,
and it has no way to reach the internet.

## The guarantees

| Property                 | How it is enforced       |
|:-------------------------|:-------------------------|
| No internet access       | No `INTERNET` permission in the manifest. The app cannot open a socket. |
| No permissions at all    | The manifest declares zero `<uses-permission>`. `build.sh` fails the build if any appear. |
| No ads, no IAP           | No third-party code of any kind. No AndroidX, no Play Billing, no analytics. |
| Never modifies your files | There is no delete, rename, move or edit code path anywhere in the app. |
| Only your chosen folder  | Access is a single persisted Storage Access Framework grant to one folder. |

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
thumbnails, and the screen pinning instructions.

Five wrong PIN entries locks the keypad for 30 seconds.

## Screen pinning

The app is designed to be left in Android's screen pinning.

Settings > Security and privacy > More security settings > App pinning. Turn it on, and
**also turn on "Ask for PIN before unpinning"**. Without that second toggle, holding back
and overview together unpins the app, which toddlers find by accident surprisingly fast.

Then open Little Videos, go to the app switcher, and pin it.

Verified on Android 13: the folder picker still opens while the app is pinned, so you do
not need to unpin to change the video folder.

## Supported files

Anything the device can decode. Tested with MP4 (H.264), MKV and WebM (VP9). Files whose
provider reports a generic MIME type are matched on extension instead: mp4, mkv, webm,
m4v, mov, avi, 3gp, 3g2, ts, m2ts, mts, mpg, mpeg, mpe, ogv, flv, wmv, asf, divx.

Subfolders are included by default, capped at 8 levels deep and 2000 files.

## Building

Needs the Android SDK (platform 35, build-tools 35.0.0) and a JDK 17 or 21. No Gradle,
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

Two rules keep the two apart. With `CI` set and no keystore at `ANDROID_KEYSTORE`,
`build.sh` refuses to run rather than quietly minting a throwaway key, because an APK
signed with the wrong key cannot install over an existing one. Locally, with `CI`
unset, it still generates the key on first run as it always has.

The GitHub release APK is signed with a different key from the one `build.sh` makes
locally, so a locally built install has to be uninstalled before a release APK will
install over it, and vice versa.

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
build.sh                           the whole build, about 120 lines
```

## Deliberate omissions

There is no seek bar in the player, only a thin non-interactive progress line. A toddler
scrubbing a video is worse than no seeking at all. Cards have no long-press behaviour, so
there is nothing to trigger by accident.
