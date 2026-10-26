# Cloud IPA build setup

This project includes a GitHub Actions workflow that runs Xcode on a hosted macOS runner, so a local Mac is not required.

## One-time setup

1. Create a private GitHub repository and upload the contents of the Moonlight-iOS folder to its root.
2. In Apple Developer, create an Apple Distribution certificate and export it as a password-protected P12 file.
3. Create an Ad Hoc provisioning profile for bundle ID com.moonlight.feed and register the iPhone UDID that will install the IPA.
4. On Windows, convert the certificate and profile to one-line Base64 values with PowerShell (copy each value directly into its matching GitHub secret):
   - [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\distribution.p12')) | Set-Clipboard
   - [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\profile.mobileprovision')) | Set-Clipboard
5. In GitHub repository Settings > Secrets and variables > Actions, add:
   - IOS_CERTIFICATE_P12_BASE64: Base64 text of the P12 file.
   - IOS_CERTIFICATE_PASSWORD: password used when exporting the P12.
   - IOS_PROVISIONING_PROFILE_BASE64: Base64 text of the .mobileprovision file.
   - IOS_KEYCHAIN_PASSWORD: a new temporary password used only by the runner.
   - IOS_TEAM_ID: Apple Developer Team ID.
6. Open Actions > iOS build > Run workflow. Download the Moonlight-iOS-IPA artifact after it finishes.

Without signing secrets, the workflow still performs an iOS Simulator build, but a simulator app cannot be installed on a physical iPhone. The Ad Hoc profile must include the device receiving the IPA.

Do not upload certificates or passwords into this chat or commit them to the repository. Use only GitHub Actions secrets.


