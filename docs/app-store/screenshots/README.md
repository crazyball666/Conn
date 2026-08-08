# ConnTerm App Store Screenshots

All assets in this directory are generated from the same booted iPhone 17 Pro simulator.

## Localized raw screenshots

- `raw/zh/`: Simplified Chinese app UI
- `raw/en/`: English app UI

Each locale contains:

1. `server-list.png`
2. `host-detail.png`
3. `terminal-output.png`
4. `docker-containers.png`
5. `script-run.png`
6. `file-browser.png`

## App Store product images

- `marketing/zh/`: Simplified Chinese marketing copy and Chinese app UI
- `marketing/en/`: English marketing copy and English app UI
- `marketing/v2/zh/`: retained 6.3-inch Chinese comparison set
- `marketing/v2/en/`: retained 6.3-inch English comparison set
- `marketing/app-store-6.9/zh/`: submission-ready Simplified Chinese set
- `marketing/app-store-6.9/en/`: submission-ready English set

The submission-ready product images use a neutral dark device frame, preserve the complete simulator screenshot, and are rendered at the accepted 6.9-inch portrait size of 1320 × 2868 pixels. They are opaque PNG files without an alpha channel.

The original and v2 product images are kept for comparison. The current compositor writes the submission set to `marketing/app-store-6.9/` and leaves the older files untouched.

Run `compose_marketing.swift` to regenerate the submission-ready marketing images from the localized raw screenshots.
