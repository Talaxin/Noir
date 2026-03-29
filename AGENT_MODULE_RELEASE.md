# Noir Build + Module Release Guide (Agents)

Use this exact runbook when releasing Noir from:
`/Users/talaxin/Documents/cursor_projs/Noir`

## Hard Rules
- Single source of truth is the `Noir` directory above.
- Git remote must be only: `https://github.com/Talaxin/Noir.git`
- Every release increments versions by `+0.0.1` (patch bump).
- Keep local files; do not delete unrelated local content.
- Push only intended release artifacts and module files.

## Files That Matter
- App project/version:
  - `Noir.xcodeproj/project.pbxproj`
- eSign/AltStore metadata:
  - `repo.json`
  - `release_esign.py`
- IPA build script:
  - `ipabuild.sh`
- Module manifests/scripts:
  - `NoirServices/Miruro/miruro.json`
  - `NoirServices/Miruro/miruro.js`
  - `NoirServices/AnimeKai/animekai.json`
  - `NoirServices/AnimeKai/animekai.js`
  - `NoirServices/TokyoInsider/tokyoinsider.json`
  - `NoirServices/TokyoInsider/tokyoinsider.js`
  - `NoirServices/HiMovies/himovies.json`
  - `NoirServices/HiMovies/himovies.js`

## Preflight Checks
1. Confirm location:
   - `pwd` must be `/Users/talaxin/Documents/cursor_projs/Noir`
2. Confirm remote:
   - `git remote -v` must show `Talaxin/Noir.git` for fetch and push.
3. Confirm no merge conflicts:
   - Search for `<<<<<<<`, `=======`, `>>>>>>>` and resolve if found.
4. Validate parsable metadata:
   - JSON and plist files must parse/lint cleanly.

## Version Bump Rule
- App + modules + repo metadata all bump patch by `+0.0.1`.
- Example: `1.0.23 -> 1.0.24`.
- Never skip bump for a release build.
- **IPA must match `repo.json`:** Before `ipabuild.sh`, set `MARKETING_VERSION` in `Noir.xcodeproj/project.pbxproj` to the **same** version you will publish in `repo.json` (that value becomes `CFBundleShortVersionString` inside the IPA). If you only bump `repo.json` and not the Xcode project, eSign will show a new version but the installed app will still report the old one.

## Build IPA
1. Run:
   - `bash ./ipabuild.sh ios`
2. Expected output IPA:
   - `build/Noir.ipa`
3. Quick sanity:
   - file exists and has non-zero size.

## Update repo.json and Module Versions
Use the helper script after IPA is built:

```bash
python3 ./release_esign.py --bump --description "Describe the release briefly."
```

What this updates:
- `repo.json` app version/date/description/size
- `repo.json` latest `versions[0]` version/date/description/size
- Module manifest versions:
  - `NoirServices/Miruro/miruro.json`
  - `NoirServices/AnimeKai/animekai.json`
  - `NoirServices/TokyoInsider/tokyoinsider.json`
  - `NoirServices/HiMovies/himovies.json`

## Validate Before Push
1. Build check:
   - `xcodebuild -project Noir.xcodeproj -scheme Noir -configuration Debug -destination "generic/platform=iOS" -quiet build`
2. Release check:
   - `xcodebuild -project Noir.xcodeproj -scheme Noir -configuration Release -destination "generic/platform=iOS" -quiet build`
3. Confirm `repo.json` version equals IPA release version.
4. Confirm module `scriptUrl` values point to:
   - `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/...`
5. Confirm intended changed files via:
   - `git status --short`

## Commit and Push
1. Stage only intended files (modules, `repo.json`, build artifact(s), related source changes).
2. Commit with clear release message.
3. Push to `origin main`.

## Post-Push Links To Verify
- Repo metadata:
  - `https://raw.githubusercontent.com/Talaxin/Noir/main/repo.json`
- IPA:
  - `https://github.com/Talaxin/Noir/raw/main/build/Noir.ipa`
- Module manifests:
  - `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/Miruro/miruro.json`
  - `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/AnimeKai/animekai.json`
  - `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/TokyoInsider/tokyoinsider.json`
  - `https://raw.githubusercontent.com/Talaxin/Noir/main/NoirServices/HiMovies/himovies.json`

## Agent Hand-off Notes
- If release metadata and IPA version ever mismatch, rebuild IPA and rerun `release_esign.py --bump`.
- Do not switch to other repositories.
- If a command needs elevated permissions, ask user once and then continue with sudo as approved.
