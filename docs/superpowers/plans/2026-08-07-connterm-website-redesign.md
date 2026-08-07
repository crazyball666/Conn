# ConnTerm Website Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current concept-heavy ConnTerm homepage with a product-first editorial landing page that uses real localized App screenshots and the App’s actual dark/purple design tokens.

**Architecture:** Keep the existing pure-static site structure. The homepage owns the product story, shared CSS provides App-aligned tokens plus separate homepage/legal-page layouts, and the existing vanilla JavaScript localization runtime gains only reveal-animation behavior. The independent privacy page remains directly accessible but is not linked or discussed by the homepage.

**Tech Stack:** Semantic HTML5, CSS, vanilla JavaScript, existing PNG screenshots, Python static server, headless Chrome for visual verification.

---

### Task 1: Package real localized product screenshots

**Files:**
- Copy from: `docs/app-store/screenshots/raw/zh/*.png`
- Copy from: `docs/app-store/screenshots/raw/en/*.png`
- Create: `docs/website/assets/product/zh/*.png`
- Create: `docs/website/assets/product/en/*.png`

- [ ] **Step 1: Copy the six Chinese and six English raw App screenshots into the website asset tree**

Use the existing filenames: `server-list.png`, `host-detail.png`, `terminal-output.png`, `docker-containers.png`, `script-run.png`, and `file-browser.png`.

- [ ] **Step 2: Verify the copied dimensions and language pairing**

Run: `sips -g pixelWidth -g pixelHeight docs/website/assets/product/{zh,en}/*.png`

Expected: every file is `1206 × 2622`, with twelve files total.

### Task 2: Rewrite the homepage product story

**Files:**
- Modify: `docs/website/index.html`

- [ ] **Step 1: Rewrite navigation and replace the current hero/fake console with the approved editorial hero**

Replace the old `#capabilities / #workflow / #faq` navigation with valid anchors for product capabilities, product screens, and support; retain language switching and add the App Store status CTA. Use the approved Chinese/English hero headlines, product-only supporting copy, App Store status CTA, and “Explore features” anchor. Render the real localized server list inside a CSS device frame.

- [ ] **Step 2: Replace card grids and workflow with the capability rail and five product chapters**

Create product chapters for host overview/detail, multi-session terminal, Docker operations, batch scripts, and remote files. Each chapter must use real paired screenshots, a short localized explanation, and 2–3 factual capability tags.

- [ ] **Step 3: Replace the closing sections and footer**

Add the approved closing CTA and support link. Remove every homepage occurrence of privacy policy, Keychain, account/cloud claims, and `/privacy/` links from navigation, content, FAQ, and footer.

- [ ] **Step 4: Add accessibility and performance attributes**

Give product images localized alt text, use `loading="lazy"` outside the hero, set intrinsic dimensions, keep semantic heading order, and mark decorative layers as hidden.

### Task 3: Rebuild shared styling with App tokens

**Files:**
- Modify: `docs/website/assets/site.css`

- [ ] **Step 1: Replace homepage tokens and composition**

Use `#0A0C14`, `#141826`, `#1A1F33`, `#1F2437`, `#EDEFF7`, `#8E95AC`, primary `#BF5AF2`, and auxiliary `#8B93FF`. Keep green/yellow/red reserved for status. Build the editorial hero, capability rail, asymmetric product chapters, CSS device frames, tags, and closing CTA.

- [ ] **Step 2: Add localized image visibility and restrained motion**

Only the matching `.shot-zh` or `.shot-en` image may display for the active root language. Add initial/reveal states and `prefers-reduced-motion` fallbacks.

- [ ] **Step 3: Preserve the legal page**

Keep dedicated `.legal-page`, `.policy-wrap`, `.policy-nav`, and `.policy-section` rules so `/privacy/` remains readable after the shared stylesheet rewrite.

- [ ] **Step 4: Add responsive layouts**

At desktop, use asymmetric alternating chapters; at tablet, simplify overlap; at 390px, stack copy above uncropped full-width product frames, collapse navigation, and prevent horizontal overflow.

### Task 4: Extend the static interaction runtime

**Files:**
- Modify: `docs/website/assets/site.js`

- [ ] **Step 1: Preserve language priority/navigation behavior and synchronize every App Store CTA**

Keep `?lang=zh|en` → localStorage → browser language, preserve hash and scroll position, and update every `[data-app-store-url]` via `querySelectorAll` so navigation, Hero, and closing CTAs share the same valid product URL or the same disabled localized “Coming soon” fallback.

- [ ] **Step 2: Add progressive reveal behavior**

Use `IntersectionObserver` to add `.is-visible` to `[data-reveal]`. If reduced motion is enabled or IntersectionObserver is unavailable, reveal content immediately.

### Task 5: Verify product content, localization, and layout

**Files:**
- Verify: `docs/website/index.html`
- Verify: `docs/website/privacy/index.html`
- Verify: `docs/website/assets/site.css`
- Verify: `docs/website/assets/site.js`
- Create/refresh: `docs/app-store/website-redesign-zh.png`
- Create/refresh: `docs/app-store/website-redesign-en.png`
- Create/refresh: `docs/app-store/website-redesign-mobile.png`

- [ ] **Step 1: Run structural and copy checks**

Run homepage-only searches to prove there is no `privacy`, `隐私`, `Keychain`, `云端`, `无账号`, or `/privacy/` reference. Verify all twelve product image paths and both locale strings exist.

- [ ] **Step 2: Run whitespace and external-resource checks**

Run `git diff --check` and scan `docs/website` for external fonts, CDNs, analytics, trackers, or missing local assets.

- [ ] **Step 3: Run the site through a local static server**

Serve `docs/website` with `python3 -m http.server`. Verify `/`, `/?lang=en`, `/privacy/`, CSS, JS, favicon, and all product PNGs return HTTP 200.

- [ ] **Step 4: Capture and inspect desktop/tablet/mobile previews**

Use headless Chrome at 1440px, 900px, and 390px. Confirm correct localized screenshots, no horizontal overflow, no clipped device content, readable navigation, and no homepage privacy content. Also confirm `/privacy/` still renders correctly as a direct page.
