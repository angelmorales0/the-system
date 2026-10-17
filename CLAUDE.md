# Project rules

## Verify every code change

After any change to Swift code, the Xcode project, `Info.plist`, entitlements,
or app resources, run the `verify` skill (`.claude/skills/verify/verify.sh`).

- A change is not implemented until the script prints `VERIFY PASSED` and the
  screenshot shows the expected screen.
- If it fails, fix the cause and run it again. Repeat until it passes.
- Do not ask the user to build in Xcode to find errors. Find them with the script.
