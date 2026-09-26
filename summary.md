# CI report

- ref: `ci/bootstrap`
- commit: `9beaadb2bf8a7fa7c8a4ba1187087f92fab64a5e`
- run: https://github.com/DevBehindYou/VaultBox/actions/runs/36252692068
- flutter: 3.47.4   exclude_saf_draft: false
- android scaffold generated this run: false

| step | outcome |
|---|---|
| pub get | success |
| build_runner (drift) | success |
| pigeon | success |
| dart format (advisory) | failure |
| flutter analyze | success |
| flutter test | failure |
| generate icon/splash | success |
| build apk (debug) | success |
| build apk (release) | success |
