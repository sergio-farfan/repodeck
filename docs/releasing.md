# Releasing RepoDeck

The scripts build a universal Apple silicon/Intel app and create a GitHub **draft**. Choose whether the draft is a prerelease before preparing it. Public publication remains an explicit maintainer action after verification. Existing releases and their assets are never overwritten.

## Prepare the source

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`, add a matching section to `CHANGELOG.md`, and update user-facing documentation.
2. Run the automated checks in [TESTING.md](../TESTING.md). Commit the version change and push it.
3. Create an annotated `vX.Y.Z` tag at that exact commit and push that tag to `origin`.
4. Check out the tag with no uncommitted or untracked source files. `Scripts/release-preflight.sh X.Y.Z` verifies that HEAD and both local and remote tags identify the same commit before any release build.

CI uses Xcode 26.3 / Swift 6.2 on macOS 15. Select that toolchain for release builds, or document the version used in the release notes. The binary's source is traceable to the verified tag; byte-for-byte reproducible code signing/DMG output is not promised.

## Build the installer

```sh
Scripts/make-dmg.sh
```

This produces `dist/RepoDeck-X.Y.Z.dmg` and its SHA-256 sidecar without contacting GitHub. By default the app is ad-hoc signed for development. Finder layout is best effort; a denied Automation prompt does not invalidate the disk image.

For a Developer ID build, use a signing identity already installed in your login keychain. For notarization, first create an Apple `notarytool` keychain profile using Apple's documented credential setup; never put passwords or signing private keys in the repository.

```sh
SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)' \
NOTARY_PROFILE='repodeck-notary' \
Scripts/make-dmg.sh
```

The signing path enables hardened runtime and a secure timestamp. With `NOTARY_PROFILE`, the script notarizes and staples the app before packaging, then signs, notarizes, and staples the final DMG. Checksums are generated only after final stapling. Omit `NOTARY_PROFILE` for a signed but unnotarized development artifact. No signing credentials are automatically installed or retrieved.

## Prepare and verify the draft

After source preparation, run the same command with `--release` to create a draft with versioned/stable DMG assets and checksum. For the combined beta, explicitly choose the prerelease channel:

```sh
Scripts/make-dmg.sh --release --prerelease
```

`--prerelease` requires `--release`, marks the GitHub draft as a prerelease, and sets `--latest=false` so it does not replace the stable download. It does not relax signing or validation gates. The app version and tag stay numeric (`X.Y.Z` / `vX.Y.Z`); prerelease status is GitHub release metadata. Give each new version its own tag. Omit `--prerelease` only when preparing a stable release draft.

The script revalidates the tag immediately before upload and uses `gh release create --verify-tag --draft` with the `origin` repository explicitly selected. An existing draft or public release is rejected; recover a failed draft deliberately in GitHub rather than replacing assets automatically.

Alternatively, run **Prepare release draft** in GitHub Actions with the already pushed tag and the **prerelease** checkbox (enabled by default). The workflow resolves the tag to a commit once, then uses the reusable CI workflow to build, run the full tests, check every shell script, and run offline packaging regressions on native Apple silicon and Intel runners. Both jobs must succeed before packaging starts. Their checkouts and the packaging checkout are pinned to the resolved commit; each stage revalidates that the app version, local tag, remote tag, and expected commit still agree. Moving a tag after validation causes refusal rather than packaging different source.

Source resolution and both validation jobs have read-only repository permissions. Only the packaging job receives release-write permission, after validation succeeds and the `release` environment gate permits it. Configure that GitHub environment with appropriate maintainers as reviewers before using it; declaring the environment in YAML does not configure its protection rules. No account secrets are passed to the reusable validation workflow.

The workflow defaults to an ad-hoc signed draft. Use the local keychain workflow above for Developer ID/notarized artifacts until CI signing credentials are deliberately provisioned. Native CI validation is automatic for workflow-created drafts; local release preparation still requires completing the automated checks on both architectures before the maintainer publishes the draft.

Download and verify the draft's checksum, architecture slices, source revision, signatures, and applicable notarization tickets. Complete the manual matrix in [TESTING.md](../TESTING.md), update the draft notes with actual results, and then publish explicitly. Enable GitHub immutable releases so published tags and assets remain fixed. Never move an already published version tag to repair a release; issue a new version.

Sources: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases), [release creation](https://cli.github.com/manual/gh_release_create).
