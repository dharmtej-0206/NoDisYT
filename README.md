# NoDisYT (iOS)

A distraction-free, focus-hardened **YouTube tweak & sideloadable IPA for iOS** based on **[YTKACE](https://github.com/itzzace/ytkace)** (v1.1.9).

## Compatibility

- **Platform:** iOS (arm64)
- **Tweak:** iOS 15.0 and newer
- **Sideloaded IPA (YouTube 21.47.6):** iOS 17.0 and newer — install with TrollStore, AltStore, SideStore, or LiveContainer

## Credits & Attribution

**NoDisYT for iOS** is built directly on top of **[YTKACE](https://github.com/itzzace/ytkace)** by **[itzzace](https://github.com/itzzace)**, licensed under the [MIT License](LICENSE). All core YouTube enhancement features (ad blocking, SponsorBlock, DeArrow, downloads, local queue, Liquid Glass, playback controls, and settings infrastructure) belong to YTKACE and its contributors. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for additional upstream notices.

## Focus Features Added in NoDisYT

- **Clean Home & Watch Surfaces**
  - Removes all Home screen recommendations (`FEwhat_to_watch`) and stops/hides the Home loading spinner (`MDCActivityIndicator` / `UIActivityIndicatorView`) so it consumes zero idle resources.
  - Removes Watch page related/suggested videos and creator end-screen recommendations.
  - Redirects Shorts (`reelWatchEndpoint`) to the standard video player (`watchEndpoint`).
- **YTBlock-Style `BLOCKED` Overlay (No Unhide Button)**
  - Replaces blocked video cards in Search, feeds, and playlists with a bordered `BLOCKED` card (red `nosign` badge + bold `BLOCKED`, light/dark mode aware) and blocks playback in the player if opened directly.
  - Filters by **channel blocklist** (59 default channels + user-blocked channels), **title keywords** (69 default keywords), and **YouTube Data API v3 categories** (cached locally for 30 days; allows only *Education*, *Entertainment*, *Howto & Style*, *People & Blogs*, and *Science & Technology* by default).
- **One-Tap 3-Dot Menu Blocking (Block-Only)**
  - Adds **Block Channel** and **Block Video** to every video's 3-dot menu.
  - Works immediately without a password and persists across app restarts.
- **Password-Protected Focus Filters Settings**
  - Accessible under **YTKACE → Focus Filters** (prompts to set a password on first open, stored as a salted SHA-256 hash).
  - Manage blocked categories, title keywords, blocked channels, and individually blocked videos only after unlocking with your password.
- **Permanently Locked Anti-Distraction Settings & Navigation Tabs**
  - Permanently removes **Shorts**, **Subscriptions**, and **Library** from the bottom navigation bar and greys out the **Tabs** settings menu.
  - Permanently locks ON and greys out 15 distraction-control toggles across Player, Watch Page, Home & Feed, and Shorts:
    - **Player**: Remove End Screen, Remove More Videos, Remove Autoplay Prompt, Remove Continue Watching, Stop Autoplay Next, Disable Previous/Next
    - **Watch Page**: Remove Suggested Videos
    - **Home & Feed**: Remove Shorts Shelves, Remove Mixes, Remove Playables
    - **Shorts**: Play Shorts Once, Remove Live Shorts, Remove Pause Suggestions, Remove Suggestion Pill, Remove Posts from Shorts

## Building Locally

### 1. Optional: Configure YouTube Data API v3 Key (for Category Filtering)
Create `Tweak/Features/Interface/FocusAPIKey.local.h` (git-ignored so your key is never committed):

```objc
static NSString *const kYTBlockAPIKey = @"YOUR_YOUTUBE_DATA_API_V3_KEY";
```

Without this file, channel, title, Home, Watch, End Screen, Shorts redirect, and 3-dot blocking still work; only API-based category lookups are skipped.

### 2. Compile & Repack
Using Theos (with an iOS 16.2+ SDK) and a decrypted YouTube `21.47.6` IPA:

```bash
make TARGET=iphone:clang:16.2:15.0
bash Scripts/sideload-repack.sh <DecryptedYouTube.ipa> dist/YTKACE.dylib NoDisYT_YouTube_21.47.6.ipa
```

## License

MIT License — see [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Full credit to **[itzzace/ytkace](https://github.com/itzzace/ytkace)** for the upstream YTKACE project.
