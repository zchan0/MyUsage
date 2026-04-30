# Release Flow

Internal docs for cutting a new MyUsage release. End users want
[README.md](../README.md) and [GitHub Releases](https://github.com/zchan0/MyUsage/releases) instead.

## Cut a release

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion` build number)
   in `MyUsage/Resources/Info.plist`.
2. Add a `## vX.Y.Z — YYYY-MM-DD` section to `CHANGELOG.md`. Bilingual:
   English first, `### 中文` block second. The release pipeline strips at
   `### 中文` so the GitHub Release page stays English-only.
3. Commit (`chore(release): bump version to X.Y.Z (build N)`).
4. Tag with `git tag -a vX.Y.Z -m "vX.Y.Z — <one-line summary>"`.
5. `git push origin main && git push origin vX.Y.Z`.
6. The `Release` workflow runs on tag push:
   - `swift test`
   - `./Scripts/prepare_release.sh --version X.Y.Z --no-update-plist`
   - Composes release notes by extracting the matching CHANGELOG section
     and appending the install block (`.github/workflows/release.yml`).
   - Publishes the GitHub Release with `MyUsage-X.Y.Z.zip` +
     `MyUsage-X.Y.Z.zip.sha256`.

## Local packaging

For a local artifact without tagging:

```bash
./Scripts/package_app.sh
# or:
./Scripts/prepare_release.sh --version 0.7.2 --build 8
```

`prepare_release.sh` updates / validates bundle version fields, packages
`MyUsage.app`, and outputs:

- `MyUsage-<version>.zip`
- `MyUsage-<version>.zip.sha256`

## When CI fails on a tag

The tag is already published, but the release workflow may not have
produced an artifact. Two cleanup paths:

- **Force-move the tag** to the fix commit and re-push (`git tag -f -a vX.Y.Z`,
  `git push --force origin vX.Y.Z`). The release workflow re-fires.
  Acceptable when no artifact reached GitHub Releases (no externally-
  visible regression).
- **Cut the next patch tag** (`vX.Y.Z+1`). Cleaner if any artifact already
  shipped under the old tag.

If the release body needs editing after publish, use:

```bash
gh release edit vX.Y.Z --notes-file path/to/notes.md
```
