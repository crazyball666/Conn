# ConnTerm Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a deployable bilingual ConnTerm product website and privacy policy page for users and App Store review.

**Architecture:** A small static site under `docs/website/` uses semantic HTML, one shared stylesheet, and a vanilla JavaScript localization layer. Privacy content is rendered from page-local Chinese/English data, with the existing Markdown policy remaining the Chinese source of truth.

**Tech Stack:** HTML5, CSS, vanilla JavaScript, Python static HTTP server for verification.

---

### Task 1: Build shared visual system and localization runtime

**Files:**
- Create: `docs/website/assets/site.css`
- Create: `docs/website/assets/site.js`

- [ ] Define the Quiet Infrastructure tokens, responsive layout primitives, navigation, cards, data panels, terminal preview, focus states, reduced-motion behavior, and mobile overflow rules in `site.css`.
- [ ] Implement `site.js` language resolution in the specified order: `?lang=zh|en`, localStorage, browser language; preserve hash and scroll position; expose a manual toggle and update `lang`/labels without external requests.
- [ ] Add safe App Store CTA behavior: use `data-app-store-url` when configured, otherwise render a disabled “Coming soon/即将上线” state.

### Task 2: Create bilingual product homepage

**Files:**
- Create: `docs/website/index.html`

- [ ] Add semantic metadata, skip link, responsive navigation, hero, capability grid, connect-observe-act workflow, terminal/data visual, local-first privacy band, FAQ, support link, and footer.
- [ ] Keep claims bounded to current ConnTerm behavior: user-owned or authorized SSH hosts, password/key auth, host monitoring, terminal/scripts, Docker, remote files, local Keychain, no account/cloud/ads/analytics; state that destructive commands and Docker operations require user confirmation and remain the user's responsibility.
- [ ] Add complete Chinese and English strings through the shared localization runtime and accessible labels for controls.

### Task 3: Create bilingual privacy policy page

**Files:**
- Create: `docs/website/privacy/index.html`
- Modify: `docs/app-store/PRIVACY_POLICY.md` (required: add the canonical children section and align the effective date)

- [ ] Render the privacy policy with the same header/footer and language switcher as the homepage.
- [ ] Cover collection/storage, Keychain, network targets, app lock/biometrics, monitoring scope, permissions, children, policy updates, contact, and effective date in both languages.
- [ ] Ensure wording remains consistent with App Store Connect declarations and the existing Markdown policy.

### Task 4: Document deployment and App Store submission usage

**Files:**
- Create: `docs/website/README.md`
- Modify: `docs/app-store/APP_STORE_SUBMISSION.md`

- [ ] Document static hosting directory mapping, `/privacy/` index routing, HTTPS requirement, custom-domain replacement, language behavior, and `curl -I` checks.
- [ ] Add a clear placeholder for the eventual absolute App Store privacy URL and point support to the canonical GitHub Issues URL.
- [ ] Keep the App Store CTA configurable and explain the pre-launch disabled state.

### Task 5: Verify the static deliverable

**Files:**
- Verify: `docs/website/index.html`
- Verify: `docs/website/privacy/index.html`
- Verify: `docs/website/assets/site.css`
- Verify: `docs/website/assets/site.js`

- [ ] Run `git diff --check`.
- [ ] Serve `docs/website` with `python3 -m http.server` and verify `curl -I /`, `/privacy/`, and key assets return 200; separately check the canonical GitHub Issues support URL is reachable.
- [ ] Check that no website file references external fonts, images, analytics, or fake product URLs; validate required Chinese/English headings and privacy URL instructions with `rg`.
- [ ] Capture local previews at desktop and a 390px mobile viewport, then inspect for clipping, horizontal overflow, and language-switch correctness.
