# PR 2085 audit evidence, captured 2026-11-22T19:57:53Z

## Head job 136676362203 (1783ccab), policy step
2026-11-21T01:17:28.5639410Z   --trusted-python "$trusted_python" \
2026-11-21T01:17:28.5639762Z   --json-out "$RUNNER_TEMP/dep-audit-report.json" \
2026-11-21T01:17:28.5640106Z   --md-out "$RUNNER_TEMP/dep-audit-report.md"
2026-11-21T01:17:28.5640376Z code=$?
2026-11-21T01:17:28.5640592Z set -e
2026-11-21T01:17:28.5640888Z # Apply repository-only exceptions without changing the shared helper.
2026-11-21T01:17:28.5641384Z python3 .github/scripts/dependency-audit-policy.py \
2026-11-21T01:17:28.5641804Z   "$RUNNER_TEMP/dep-audit-report.json" \
2026-11-21T01:17:28.5642122Z   .github/dependency-audit-ignore.json "$code"
2026-11-21T01:17:28.5656050Z shell: /usr/bin/bash -e {0}
2026-11-21T01:17:28.5656380Z env:
2026-11-21T01:17:28.5656640Z   pythonLocation: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-21T01:17:28.5657016Z   PKG_CONFIG_PATH: /opt/hostedtoolcache/Python/3.12.16/x64/lib/pkgconfig
2026-11-21T01:17:28.5657373Z   Python_ROOT_DIR: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-21T01:17:28.5657965Z   Python2_ROOT_DIR: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-21T01:17:28.5658312Z   Python3_ROOT_DIR: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-21T01:17:28.5658635Z   LD_LIBRARY_PATH: /opt/hostedtoolcache/Python/3.12.16/x64/lib
2026-11-21T01:17:28.5658972Z ##[endgroup]
2026-11-21T01:18:13.6329988Z ##[group]Run if [ -f "$RUNNER_TEMP/dep-audit-report.md" ]; then
2026-11-21T01:18:13.6330417Z if [ -f "$RUNNER_TEMP/dep-audit-report.md" ]; then
2026-11-21T01:18:13.6330687Z   {
2026-11-21T01:18:13.6330917Z     cat "$RUNNER_TEMP/dep-audit-report.md"
2026-11-21T01:18:13.6331906Z     echo 'Policy: The job fails on HIGH or CRITICAL findings unless a valid, unexpired repository ignore applies. Invalid ignore entries fail the job. It also fails when the audit cannot complete (helper exit 3, incomplete coverage, such as a registry outage) or a severity is Unknown (exit 4). MODERATE (Medium) and LOW are reported only.'
2026-11-21T01:18:13.6332819Z   } >> "$GITHUB_STEP_SUMMARY"
2026-11-21T01:18:13.6333061Z else
2026-11-21T01:18:13.6333381Z   echo '## Dependency audit: FAILED - no report was produced.' >> "$GITHUB_STEP_SUMMARY"

## Base job 134624010252 (ca8de8c0), policy step
2026-11-18T06:30:30.2433727Z   --trusted-python "$trusted_python" \
2026-11-18T06:30:30.2434025Z   --json-out "$RUNNER_TEMP/dep-audit-report.json" \
2026-11-18T06:30:30.2434328Z   --md-out "$RUNNER_TEMP/dep-audit-report.md"
2026-11-18T06:30:30.2434576Z code=$?
2026-11-18T06:30:30.2434740Z set -e
2026-11-18T06:30:30.2435010Z # Apply repository-only exceptions without changing the shared helper.
2026-11-18T06:30:30.2435528Z python3 .github/scripts/dependency-audit-policy.py \
2026-11-18T06:30:30.2435853Z   "$RUNNER_TEMP/dep-audit-report.json" \
2026-11-18T06:30:30.2436131Z   .github/dependency-audit-ignore.json "$code"
2026-11-18T06:30:30.2477038Z shell: /usr/bin/bash -e {0}
2026-11-18T06:30:30.2477239Z env:
2026-11-18T06:30:30.2477460Z   pythonLocation: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-18T06:30:30.2477819Z   PKG_CONFIG_PATH: /opt/hostedtoolcache/Python/3.12.16/x64/lib/pkgconfig
2026-11-18T06:30:30.2478158Z   Python_ROOT_DIR: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-18T06:30:30.2478459Z   Python2_ROOT_DIR: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-18T06:30:30.2478754Z   Python3_ROOT_DIR: /opt/hostedtoolcache/Python/3.12.16/x64
2026-11-18T06:30:30.2479054Z   LD_LIBRARY_PATH: /opt/hostedtoolcache/Python/3.12.16/x64/lib
2026-11-18T06:30:30.2479318Z ##[endgroup]
2026-11-18T06:31:26.0589047Z Blocking: High @npmcli/run-script — @npmcli/package-json
2026-11-18T06:31:26.0590063Z Blocking: High fdir — picomatch
2026-11-18T06:31:26.0591016Z Blocking: High node-gyp — tinyglobby
2026-11-18T06:31:26.0593601Z Blocking: High picomatch — https://github.com/advisories/GHSA-fc5q-39xc-vjpf
2026-11-18T06:31:26.0594244Z Blocking: High tinyglobby — fdir
2026-11-18T06:31:26.0594780Z Blocking: High @next/eslint-plugin-next — fast-glob
2026-11-18T06:31:26.0595415Z Blocking: High @typescript-eslint/typescript-estree — minimatch
2026-11-18T06:31:26.0596117Z Blocking: High eslint-config-next — @next/eslint-plugin-next
2026-11-18T06:31:26.0596843Z Blocking: High eslint-import-resolver-typescript — tinyglobby
2026-11-18T06:31:26.0597671Z Blocking: High fast-glob — micromatch
2026-11-18T06:31:26.0598133Z Blocking: High fdir — picomatch
2026-11-18T06:31:26.0598591Z Blocking: High micromatch — picomatch
2026-11-18T06:31:26.0599320Z Blocking: High picomatch — https://github.com/advisories/GHSA-fc5q-39xc-vjpf
2026-11-18T06:31:26.0599964Z Blocking: High tinyglobby — fdir
2026-11-18T06:31:26.0600380Z Blocking: High vite — picomatch
2026-11-18T06:31:26.0600822Z Blocking: High vitest — @vitest/coverage-v8
2026-11-18T06:31:26.0636002Z ##[error]Process completed with exit code 1.
2026-11-18T06:31:26.0687647Z ##[group]Run if [ -f "$RUNNER_TEMP/dep-audit-report.md" ]; then
2026-11-18T06:31:26.0688044Z if [ -f "$RUNNER_TEMP/dep-audit-report.md" ]; then
2026-11-18T06:31:26.0688304Z   {
2026-11-18T06:31:26.0688511Z     cat "$RUNNER_TEMP/dep-audit-report.md"
2026-11-18T06:31:26.0689490Z     echo 'Policy: The job fails on HIGH or CRITICAL findings unless a valid, unexpired repository ignore applies. Invalid ignore entries fail the job. It also fails when the audit cannot complete (helper exit 3, incomplete coverage, such as a registry outage) or a severity is Unknown (exit 4). MODERATE (Medium) and LOW are reported only.'
2026-11-18T06:31:26.0690421Z   } >> "$GITHUB_STEP_SUMMARY"

## Advisory record
{'ghsa_id': 'GHSA-fc5q-39xc-vjpf', 'summary': 'Withdrawn Advisory: picomatch vulnerable to ReDoS through single-branch repeated extglobs', 'published_at': '2026-10-19T18:32:12Z', 'withdrawn_at': '2026-11-18T15:38:56Z', 'updated_at': '2026-11-19T16:07:41Z'}
