(() => {
  "use strict";

  const supported = new Set(["zh", "en"]);
  const storageKey = "connterm-site-language";
  const root = document.documentElement;

  const languageFromQuery = () => {
    const value = new URLSearchParams(window.location.search).get("lang");
    return supported.has(value) ? value : null;
  };

  const languageFromStorage = () => {
    try {
      const value = window.localStorage.getItem(storageKey);
      return supported.has(value) ? value : null;
    } catch (_) {
      return null;
    }
  };

  const browserLanguage = () => navigator.language && navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en";
  let language = languageFromQuery() || languageFromStorage() || browserLanguage();

  const textNodes = [...document.querySelectorAll("[data-i18n]")];
  const htmlNodes = [...document.querySelectorAll("[data-i18n-html]")];
  const attrNodes = [...document.querySelectorAll("[data-i18n-attr]")];

  const applyLanguage = (nextLanguage, { replaceQuery = false } = {}) => {
    if (!supported.has(nextLanguage)) return;
    const previousScroll = window.scrollY;
    language = nextLanguage;
    root.lang = language === "zh" ? "zh-CN" : "en";
    root.dataset.lang = language;

    if (document.body.classList.contains("home-page")) {
      document.title = language === "zh"
        ? "ConnTerm — iPhone 上的 SSH 服务器运维工作台"
        : "ConnTerm — SSH Server Operations for iPhone";
      const description = document.querySelector('meta[name="description"]');
      if (description) {
        description.content = language === "zh"
          ? "ConnTerm 是面向 iPhone 的 SSH 服务器运维工作台，支持主机监控、终端、Docker、脚本和远程文件。"
          : "ConnTerm is an iPhone SSH operations workbench for host monitoring, terminals, Docker, scripts, and remote files.";
      }
    }

    textNodes.forEach((node) => {
      const value = node.dataset[`i18n${language === "zh" ? "Zh" : "En"}`];
      if (value !== undefined) node.textContent = value;
    });
    htmlNodes.forEach((node) => {
      const value = node.dataset[`i18nHtml${language === "zh" ? "Zh" : "En"}`];
      if (value !== undefined) node.innerHTML = value;
    });
    attrNodes.forEach((node) => {
      const [attribute, zhValue, enValue] = node.dataset.i18nAttr.split("|");
      node.setAttribute(attribute, language === "zh" ? zhValue : enValue);
    });

    document.querySelectorAll("[data-lang-label]").forEach((node) => {
      node.textContent = language === "zh" ? "EN" : "中";
    });
    document.querySelectorAll("[data-lang-label-full]").forEach((node) => {
      node.textContent = language === "zh" ? "English" : "中文";
    });
    document.querySelectorAll("[data-lang-switch]").forEach((node) => {
      node.setAttribute("aria-label", language === "zh" ? "Switch to English" : "切换为中文");
    });
    document.querySelectorAll("[data-lang-hint]").forEach((node) => {
      node.textContent = language === "zh" ? "EN" : "中";
    });

    try { window.localStorage.setItem(storageKey, language); } catch (_) { /* private browsing */ }
    if (replaceQuery) {
      const url = new URL(window.location.href);
      url.searchParams.set("lang", language);
      window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`);
    }
    window.requestAnimationFrame(() => window.scrollTo({ top: previousScroll, behavior: "auto" }));
  };

  document.querySelectorAll("[data-lang-switch]").forEach((button) => {
    button.addEventListener("click", () => applyLanguage(language === "zh" ? "en" : "zh", { replaceQuery: true }));
  });

  const nav = document.querySelector(".nav");
  const menu = document.querySelector("[data-menu-toggle]");
  if (nav && menu) {
    menu.addEventListener("click", () => {
      const isOpen = nav.classList.toggle("is-open");
      menu.setAttribute("aria-expanded", String(isOpen));
    });
    nav.querySelectorAll(".nav-links a").forEach((link) => link.addEventListener("click", () => nav.classList.remove("is-open")));
  }

  document.querySelectorAll("[data-app-store-url]").forEach((appStore) => {
    const target = appStore.dataset.appStoreUrl.trim();
    if (target && /^https:\/\//i.test(target)) {
      appStore.href = target;
      appStore.classList.remove("button-disabled");
      appStore.removeAttribute("aria-disabled");
    } else {
      appStore.removeAttribute("href");
      appStore.classList.add("button-disabled");
      appStore.setAttribute("aria-disabled", "true");
      appStore.setAttribute("role", "status");
    }
  });

  const revealNodes = [...document.querySelectorAll("[data-reveal]")];
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (revealNodes.length) {
    if (reducedMotion || !("IntersectionObserver" in window)) {
      revealNodes.forEach((node) => node.classList.add("is-visible"));
    } else {
      root.classList.add("reveal-ready");
      const observer = new IntersectionObserver((entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        });
      }, { rootMargin: "0px 0px -7%", threshold: 0.08 });
      revealNodes.forEach((node) => observer.observe(node));
      window.setTimeout(() => {
        revealNodes
          .filter((node) => node.getBoundingClientRect().top < window.innerHeight)
          .forEach((node) => node.classList.add("is-visible"));
      }, 120);
    }
  }

  applyLanguage(language);
})();
