# Releasing RepoDeck

The scripts build a universal Apple silicon/Intel app and create a GitHub **draft**. Choose whether the draft is a prerelease before preparing it. Public publication remains an explicit maintainer action after reviewing verification results and any outstanding checks. Existing tags and assets are never overwritten; an existing draft can be promoted with explicit authorization as described below.

RepoDeck's standard release is **ad-hoc signed and unnotarized**. The maintainer is not enrolled in the Apple Developer Program; Developer ID signing and notarization are optional future improvements, not prerequisites for a GitHub release. Record validation of the actual distribution, including whether first launch on clean supported Macs was tested, and state its signing status in the release notes.

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

This produces `dist/RepoDeck-X.Y.Z.dmg` and its SHA-256 sidecar without contacting GitHub. By default the app uses the project's standard ad-hoc signature and is not notarized. Finder layout is best effort; a denied Automation prompt does not invalidate the disk image.

If the maintainer later chooses Developer ID distribution, use an identity already installed in the login keychain. Optional notarization additionally uses an Apple `notarytool` keychain profile. This path requires the appropriate Apple membership and credentials; it does not apply to standard RepoDeck releases. Never put passwords or signing private keys in the repository.

```sh
SIGN_IDENTITY='Developer ID Application: Your Organization (TEAMID)' \
NOTARY_PROFILE='repodeck-notary' \
Scripts/make-dmg.sh
```

The signing path enables hardened runtime and a secure timestamp. With `NOTARY_PROFILE`, the script notarizes and staples the app before packaging, then signs, notarizes, and staples the final DMG. Checksums are generated only after final stapling. Omit `NOTARY_PROFILE` for a signed but unnotarized development artifact. No signing credentials are automatically installed or retrieved.

## Prepare and verify the draft

After source preparation, run the same command with `--release` to create a stable-channel draft with versioned/stable DMG assets and checksum:

```sh
Scripts/make-dmg.sh --release
```

Add `--prerelease` when the maintainer chooses a beta. That flag requires `--release`, marks the GitHub draft as a prerelease, and sets `--latest=false` so it does not replace the stable download. The same source, checksum, testing, and installer checks apply to beta and stable releases; neither requires Developer ID signing or notarization. The app version and tag stay numeric (`X.Y.Z` / `vX.Y.Z`); prerelease status is GitHub release metadata. Give each new version its own tag.

The script revalidates the tag immediately before upload and uses `gh release create --verify-tag --draft` with the `origin` repository explicitly selected. An existing draft or public release is rejected; recover a failed draft deliberately in GitHub rather than replacing assets automatically.

Alternatively, run **Prepare release draft** in GitHub Actions with the already pushed tag and the **prerelease** checkbox (enabled by default). The workflow resolves the tag to a commit once, then uses the reusable CI workflow to build, run the full tests, check every shell script, and run offline packaging regressions on native Apple silicon and Intel runners. Both jobs must succeed before packaging starts. Their checkouts and the packaging checkout are pinned to the resolved commit; each stage revalidates that the app version, local tag, remote tag, and expected commit still agree. Moving a tag after validation causes refusal rather than packaging different source.

Source resolution and both validation jobs have read-only repository permissions. Only the packaging job receives release-write permission, after validation succeeds and the `release` environment gate permits it. Configure that GitHub environment with appropriate maintainers as reviewers before using it; declaring the environment in YAML does not configure its protection rules. No account secrets are passed to the reusable validation workflow.

The workflow defaults to an ad-hoc signed draft. Use the local keychain workflow above for Developer ID/notarized artifacts until CI signing credentials are deliberately provisioned. Native CI validation is automatic for workflow-created drafts; local release preparation still requires completing the automated checks on both architectures before the maintainer publishes the draft.

Download and verify the draft's checksum, architecture slices, source revision, signatures, and applicable notarization tickets. Review the manual matrix in [TESTING.md](../TESTING.md), record actual results and outstanding checks in the draft notes, and obtain the maintainer's explicit publication decision for the chosen channel. The maintainer may authorize publication with documented manual-validation limits; do not turn that decision into a claim those checks passed. Enable GitHub immutable releases so published tags and assets remain fixed. Never move an already published version tag to repair a release; issue a new version.

## Promote an existing draft to stable

An explicit instruction to publish an already verified draft as stable authorizes changing its release metadata. Reuse the existing tag and assets; do not rerun packaging, replace uploads, or create another release. Confirm the draft's source against its recorded CI commit and verify the downloaded assets first. Update its title and notes for the stable channel, including any acknowledged validation limits.

The following shows the 1.10.1 promotion, authorized and completed on September 13, 2026. For another version, substitute its tag and previously verified source commit. Run the tag check from a clean checkout at that tag:

```sh
Scripts/validate-release-tag.sh v1.10.1 0c4d47afc26e05aaa0362516287a73ef86098b5e
gh release view v1.10.1 --repo sergio-farfan/repodeck \
  --json tagName,isDraft,isPrerelease,assets
gh release edit v1.10.1 --repo sergio-farfan/repodeck \
  --draft=false --prerelease=false --latest --verify-tag
gh release view v1.10.1 --repo sergio-farfan/repodeck \
  --json tagName,isDraft,isPrerelease,publishedAt,url,assets
```

`--verify-tag` requires the existing remote tag; the preceding source check verifies that it still identifies the recorded commit. Confirm the result is public and stable, that GitHub's latest release resolves to this version, and that the unauthenticated evergreen download matches the verified installer checksum. Version [1.11.0](https://github.com/sergio-farfan/repodeck/releases/tag/v1.11.0) is the current stable/latest release. The commands above retain the historical 1.10.1 example; use the new version’s exact verified commit when preparing or promoting another release. Version 1.10.0 remains an unpublished, superseded draft; its additions ship in 1.10.1.

For standard unnotarized releases, verify the ad-hoc app signature and disclose the first-launch requirement. After attempting to open a trusted, checksum-verified download, users may need **System Settings → Privacy & Security → Open Anyway**. Availability can depend on macOS and device-management policy; use [Apple's app-specific instructions](https://support.apple.com/en-lamr/102445). Check notarization tickets only when a release is actually advertised as notarized.

Sources: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases), [release creation](https://cli.github.com/manual/gh_release_create).
