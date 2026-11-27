## Install

1. Download `Studio-<version>.dmg` below, open it and drag **Studio** to **Applications**.
2. This build is not notarized, so macOS blocks the first launch. Open Studio once, then go to
   **System Settings ▸ Privacy & Security** and click **Open Anyway**. On macOS 15 and later,
   right-click ▸ Open no longer skips this step. Or, in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Studio.app
   ```

Requires macOS 15 or later (Apple silicon or Intel) and a running Django AI SDK server.
To check the download, run `shasum -a 256 -c SHA256SUMS` in the folder with both files.

Changes and known limitations: [CHANGELOG.md](https://github.com/django-ai-sdk/studio/blob/main/CHANGELOG.md).
