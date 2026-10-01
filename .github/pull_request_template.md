## What this changes



## Label

The release version comes from labels on merged PRs, so an unlabelled PR is
released as a patch bump with no changelog category. Pick one:

- [ ] `breaking` or `major` - incompatible change
- [ ] `feature` or `minor` - new capability
- [ ] `fix` or `bug` - bug fix
- [ ] `build` - build script or toolchain
- [ ] `ci` - workflows and automation
- [ ] `documentation` - README, F-Droid metadata, docs

## Checklist

- [ ] `./build.sh` passes, including the zero-permission assertion
- [ ] `./build.sh && ./tools/verify-reproducible.sh` passes, if the build changed
- [ ] `./tools/check-metadata.sh` passes, if store metadata changed
- [ ] No new `<uses-permission>` in the manifest, and no third-party code
