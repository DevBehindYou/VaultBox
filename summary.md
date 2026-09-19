# CI report

- ref: `ci/bootstrap`
- commit: `c8aabcf2abd363dc1939bd695ec9056f87154ee9`
- run: https://github.com/DevBehindYou/VaultBox/actions/runs/35446276492
- flutter: 3.47.4   exclude_saf_draft: false
- android scaffold generated this run: false

| step | outcome |
|---|---|
| pub get | success |
| build_runner (drift) | success |
| pigeon | success |
| dart format (advisory) | failure |
| flutter analyze | failure |
| flutter test | failure |
| build apk (debug) | success |
