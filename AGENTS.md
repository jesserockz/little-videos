# Agent instructions

Little Videos is a local-only Android video player for a toddler. See
[README.md](README.md) for the full picture; this file covers what an agent needs
to work on it safely.

## Hard rules

- No permissions. The manifest declares zero `<uses-permission>`, and `build.sh`
  fails the build if any appear. Never add one, including `INTERNET`.
- No third-party code. No AndroidX, no Gradle, no libraries, no analytics.
- No code path that deletes, renames, moves or edits the user's files.
- The package id is `io.github.jesserockz.littlevideos`. Do not change it.
- Never commit a keystore or signing material.

## Building and checking

Needs the Android SDK (platform 35, build-tools 35.0.0) and JDK 17. JDK 21 builds
but changes the APK hash, which breaks reproducibility.

| Command                                   | When to run                               |
|:------------------------------------------|:------------------------------------------|
| `./build.sh`                              | Always                                    |
| `./tools/verify-reproducible.sh`          | After `./build.sh`, if the build changed  |
| `./tools/check-metadata.sh`               | If store or F-Droid metadata changed      |
| `./tools/test-tools.sh`                   | If anything under `tools/` changed        |
| `yamllint --strict -c .yamllint.yml .`    | If any YAML changed                       |

`tools/smoke-test.sh` installs the APK on a connected device or emulator, launches
it and reports crashes. `tools/shot.sh <name>` saves a screenshot to `shots/`.

## Pull requests

- Fill out [the PR template](.github/pull_request_template.md) and pick exactly
  one label. The label decides the release version bump.
- **Any PR that adds or changes UI must include screenshots and a screen
  recording** of the change running on a device or emulator, attached to the PR
  description. Cover each screen or state the change touches, in both
  orientations if layout is affected. Capture them with:

  ```sh
  tools/shot.sh <name>
  adb shell screenrecord /sdcard/demo.mp4   # Ctrl+C to stop, max 3 minutes
  adb pull /sdcard/demo.mp4
  ```

  Do not commit the captures to the repo; attach them to the PR instead.
