# Notes for Claude

## Pull requests

Every PR that adds or changes a user-facing feature gets screenshots of it in the
PR description, under a `## Screenshots` heading. Show the screens the feature
adds or changes, not just the grid. Bug fixes with a visible effect get a
before and after where that helps.

The GitHub API cannot upload images into a PR description. To host them, commit
the PNGs under `.github/pr-screenshots/<PR number>/` in one commit, remove them
in the next commit, and link them by the first commit's SHA:

```
![Settings](https://github.com/jesserockz/little-videos/blob/<sha>/.github/pr-screenshots/<n>/settings.png?raw=true)
```

The links stay valid because the commit stays in the PR's history, and a squash
merge keeps the images out of `main`.

## Taking screenshots without a device

Cloud containers have no KVM, so there is no emulator, and `dl.google.com`
(the SDK, `aapt2`, Google Maven) is blocked. What works:

- **Resources:** `apt-get install aapt android-sdk-platform-23`, then
  `aapt package` against `/usr/lib/android-sdk/platforms/android-23/android.jar`,
  on a scratch copy of `app/src/main` with `android:roundIcon` deleted from the
  manifest (API 23 does not know it). This also writes `R.java`.
- **Rendering:** Robolectric 4.14 from Maven Central, with
  `@GraphicsMode(NATIVE)`, `@Config(sdk = 34, qualifiers = "w393dp-h852dp-port-xhdpi")`,
  and `test_config.properties` pointing at the resource APK and manifest.
  Compile against `org.robolectric:android-all`, not the instrumented jar.
  Draw the activity's decor view into a `Bitmap` and save it as a PNG.
- **`androidx.test:monitor`** is only on Google Maven. Exclude `androidx.test*`
  from the Robolectric dependency and build monitor from
  `github.com/android/android-test` at tag `axt_08_14_2024`
  (`runner/monitor/java`). Stub `androidx.annotation` and `androidx.tracing.Trace`,
  port its two Kotlin files to Java, compile with the
  `internal/runner/hidden` shim, then swap in the `internal/runner/runtime`
  `ExposedInstrumentationApi` class.

System UI, such as the "Pin app?" prompt, cannot be rendered this way. Say so in
the PR rather than leaving it out silently.
