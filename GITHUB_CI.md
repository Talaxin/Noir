# GitHub CI → Feather

Noir builds on GitHub Actions and publishes `build/Noir.ipa` + `repo.json` to **`main`**, which Feather uses.

## Feather source URL

```
https://raw.githubusercontent.com/Talaxin/Noir/main/repo.json
```

## How to release a new build

1. **Work on the `full-project` branch** (full Xcode source lives here).
2. **Bump the app version** in `Noir.xcodeproj/project.pbxproj` (`MARKETING_VERSION`, e.g. `1.0.40` → `1.0.41`).
3. **Commit and push** to `full-project`:
   ```bash
   git checkout full-project
   git add .
   git commit -m "Your changes"
   git push origin full-project
   ```
4. **GitHub Actions** runs automatically:
   - Builds `build/Noir.ipa`
   - Updates `repo.json` (version from IPA, size, date)
   - Pushes IPA + `repo.json` to **`main`**
5. **On your phone:** open Feather → refresh the Noir source → update/install.

## Manual build trigger

GitHub → **Actions** → **Build IPA for Feather** → **Run workflow** (optional release notes).

## Notes

- CI commits use `[skip ci]` so publishing the IPA does not re-trigger another build.
- Only pushes that change source files trigger CI (not IPA/repo-only commits).
- Bump `MARKETING_VERSION` before pushing if you want Feather to show a new version number.
