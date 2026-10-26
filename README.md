# Moonlight iOS port

Native SwiftUI port of the Android MoonDiary v5.0 app. The deployment target remains iOS 16, matching the existing IPA; iOS 26+ uses GlassEffectContainer while earlier versions use a material fallback.

## Migration scope

- Home feed, Discover/search, Library/downloads/trash, Moments/social/chat/profiles, camera/recording, Sources, and settings.
- Fixes and additions requested in chat: portrait-only playback, pull-to-refresh, reliable previews and media picking, fade deletion, Bilibili post previews, select-all, native system icons, YouTube visibility/playback, random source insertion, expanded background coverage, gesture guide, configurable Discover banners, five circular Liquid Glass tabs, configurable long-press modes, and removal/unification of the redundant top banner.
- Additional functionality: opt-in virtual-friend posting, reactions and AI-generated text via a configured provider. Automatic posting stays off until explicitly enabled and configured.

## Current state

Initial iOS project scaffold. The supplied Android source is the functional reference; Android framework code must be rewritten with SwiftUI, AVFoundation/AVKit, PhotosUI, URLSession, BackgroundTasks and CloudKit where appropriate. No iOS source was included in the IPA.

## Build

This workspace runs on Windows and has no local Xcode toolchain. The included GitHub Actions workflow builds on a GitHub-hosted macOS runner and exports a signed Ad Hoc IPA when signing secrets are configured.

The current visual pass uses compact page headers, warm system backgrounds, consistent rounded cards, a two-column Discover preview with a one/two-column toggle, and a five-button tab bar. Red-marked screenshots are treated as layout guidance; cards and content are preserved. Placeholder tiles and empty states still need to be connected to the migrated data layer.

## Cloud IPA build

The existing IPA is com.moonlight.feed, version 1.2 (build 7), with minimum iOS 16. The Xcode target keeps the same bundle ID, raises the app to version 2.0 (build 8), and keeps iOS 16 support.

To build without owning a Mac, upload this project to a private GitHub repository. Add Actions secrets for an Apple Distribution certificate (.p12) encoded as Base64, its password, an Ad Hoc provisioning profile for com.moonlight.feed that includes the target iPhone, the Apple Team ID, and a temporary keychain password. Run Actions > iOS build and download the Moonlight-iOS-IPA artifact. Without signing secrets, the workflow still builds and uploads a simulator app, but that artifact cannot be installed on an iPhone.

Do not paste signing certificates or passwords into chat or commit them to the repository.

