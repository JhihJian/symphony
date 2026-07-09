(function () {
  var mermaidInitialized = false;
  var renderSequence = 0;
  var revealObserver = null;
  var revealQueued = false;
  var pageOutlineObserver = null;
  var pageOutlineMutationObserver = null;
  var pageOutlineQueued = false;
  var pageOutlineEntries = [];
  var revealSelector = [
    ".hero-card",
    ".section-card",
    ".metric-card",
    ".hub-summary-panel",
    ".instance-card",
    ".workflow-status-chip",
    ".stage-detail-card",
    ".notice-banner",
    ".admin-control-boundary"
  ].join(",");
  var pageOutlineTargetSelector = [
    ".dashboard-shell > .hero-card",
    ".dashboard-shell > .error-card",
    ".dashboard-shell > .notice-banner",
    ".dashboard-shell > .admin-control-boundary",
    ".dashboard-shell > .workflow-status-strip",
    ".dashboard-shell > .workflow-layout > .section-card",
    ".dashboard-shell > .workflow-detail-strip > .section-card",
    ".dashboard-shell > .section-card",
    ".dashboard-shell > details.hub-diagnostic-disclosure"
  ].join(",");

  function initializeMermaid() {
    if (!window.mermaid) return false;
    if (mermaidInitialized) return true;

    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      flowchart: {
        curve: "basis",
        htmlLabels: false,
        nodeSpacing: 88,
        rankSpacing: 130,
        padding: 22
      },
      themeVariables: {
        primaryColor: "#ffffff",
        primaryTextColor: "#111111",
        primaryBorderColor: "#eaeaea",
        lineColor: "#787774",
        fontSize: "16px",
        fontFamily: "SF Pro Display, Geist Sans, Helvetica Neue, Switzer, sans-serif"
      }
    });

    mermaidInitialized = true;
    return true;
  }

  function parseStageMap(element) {
    try {
      return JSON.parse(element.getAttribute("data-stage-map") || "{}");
    } catch (_error) {
      return {};
    }
  }

  function renderWorkflowMermaid(element) {
    var source = element.querySelector("[data-mermaid-source]");
    var output = element.querySelector("[data-mermaid-output]");
    var definition = source ? source.textContent.trim() : "";
    var signature = element.getAttribute("data-mermaid-signature") || definition;

    if (!definition || !output) return;

    if (!initializeMermaid()) {
      output.innerHTML = "<div class=\"empty-state\">Mermaid 静态资源未加载。</div>";
      return;
    }

    if (element.__workflowMermaidSignature === signature && output.querySelector("svg")) return;

    var sequence = ++renderSequence;
    var renderId = "workflow-mermaid-" + sequence;
    element.__workflowMermaidSignature = signature;
    output.classList.add("workflow-mermaid-loading");

    window.mermaid
      .render(renderId, definition)
      .then(function (result) {
        if (element.__workflowMermaidSignature !== signature) return;

        output.innerHTML = result.svg;
        output.classList.remove("workflow-mermaid-loading");

        var svg = output.querySelector("svg");
        if (svg) {
          svg.setAttribute("role", "img");
          svg.setAttribute("aria-label", "Workflow stage graph");
          svg.removeAttribute("height");
          svg.removeAttribute("width");
        }

        attachRenderedNodeHandlers(output, parseStageMap(element), function (stageId) {
          if (typeof element.__workflowPushStage === "function") {
            element.__workflowPushStage(stageId);
          }
        });
      })
      .catch(function (error) {
        output.classList.remove("workflow-mermaid-loading");
        renderWorkflowMermaidError(output, error);
      });
  }

  function renderWorkflowMermaidError(output, error) {
    var card = document.createElement("div");
    var title = document.createElement("h2");
    var copy = document.createElement("p");

    card.className = "error-card workflow-mermaid-error";
    title.className = "error-title";
    title.textContent = "Workflow 图渲染失败";
    copy.className = "error-copy";
    copy.textContent = String(error && error.message ? error.message : error);

    card.appendChild(title);
    card.appendChild(copy);
    output.replaceChildren(card);
  }

  function attachRenderedNodeHandlers(output, stageMap, pushStage) {
    output.querySelectorAll("g.node").forEach(function (node) {
      var title = node.querySelector("title");
      var nodeKeys = [
        node.getAttribute("data-id"),
        node.id,
        node.id ? node.id.replace(/^flowchart-/, "").replace(/-\d+$/, "") : null,
        title ? title.textContent : null
      ];
      var stageId = null;

      for (var index = 0; index < nodeKeys.length; index += 1) {
        var nodeKey = nodeKeys[index];
        if (nodeKey && stageMap[nodeKey]) {
          stageId = stageMap[nodeKey];
          break;
        }
      }

      if (!stageId && node.id) {
        Object.keys(stageMap).some(function (nodeKey) {
          if (node.id.indexOf("flowchart-" + nodeKey + "-") >= 0) {
            stageId = stageMap[nodeKey];
            return true;
          }

          return false;
        });
      }

      if (!stageId) return;

      node.classList.add("workflow-mermaid-node-clickable");
      node.setAttribute("tabindex", "0");
      node.setAttribute("role", "button");
      node.setAttribute("aria-label", "Show details for workflow stage " + stageId);

      node.addEventListener("click", function () {
        pushStage(stageId);
      });

      node.addEventListener("keydown", function (event) {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          pushStage(stageId);
        }
      });

      node.addEventListener("focus", function () {
        node.classList.add("workflow-mermaid-node-focused");
      });

      node.addEventListener("blur", function () {
        node.classList.remove("workflow-mermaid-node-focused");
      });
    });
  }

  function renderAllWorkflowMermaid() {
    document.querySelectorAll(".workflow-mermaid[data-mermaid-signature]").forEach(function (element) {
      renderWorkflowMermaid(element);
    });
  }

  var renderAllQueued = false;

  function queueRenderAllWorkflowMermaid() {
    if (renderAllQueued) return;

    renderAllQueued = true;
    window.setTimeout(function () {
      renderAllQueued = false;
      renderAllWorkflowMermaid();
    }, 0);
  }

  function watchWorkflowMermaid() {
    if (!window.MutationObserver || !document.body) return;

    var observer = new window.MutationObserver(queueRenderAllWorkflowMermaid);
    observer.observe(document.body, {childList: true, subtree: true});
  }

  function startWorkflowMermaidRendering() {
    renderAllWorkflowMermaid();
    window.setTimeout(renderAllWorkflowMermaid, 250);
    window.setTimeout(renderAllWorkflowMermaid, 1000);
    watchWorkflowMermaid();
  }

  function prefersReducedMotion() {
    return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  }

  function revealElement(element) {
    element.classList.add("reveal-visible");
    element.classList.remove("reveal-ready");
    if (revealObserver) revealObserver.unobserve(element);
  }

  function initializeRevealObserver() {
    if (prefersReducedMotion()) {
      document.querySelectorAll(revealSelector).forEach(revealElement);
      return;
    }

    if (!("IntersectionObserver" in window)) {
      document.querySelectorAll(revealSelector).forEach(revealElement);
      return;
    }

    if (!revealObserver) {
      revealObserver = new window.IntersectionObserver(
        function (entries) {
          entries.forEach(function (entry) {
            if (entry.isIntersecting) revealElement(entry.target);
          });
        },
        {rootMargin: "0px 0px -8% 0px", threshold: 0.08}
      );
    }

    document.querySelectorAll(revealSelector).forEach(function (element, index) {
      if (element.getAttribute("data-reveal-bound") === "true") return;

      element.setAttribute("data-reveal-bound", "true");
      element.style.setProperty("--reveal-delay", Math.min(index % 6, 4) * 80 + "ms");
      element.classList.add("reveal-ready");
      revealObserver.observe(element);
    });
  }

  function queueRevealObserver() {
    if (revealQueued) return;

    revealQueued = true;
    window.setTimeout(function () {
      revealQueued = false;
      initializeRevealObserver();
    }, 0);
  }

  function watchRevealTargets() {
    if (!window.MutationObserver || !document.body) return;

    var observer = new window.MutationObserver(queueRevealObserver);
    observer.observe(document.body, {childList: true, subtree: true});
  }

  function compactText(value) {
    return String(value || "")
      .replace(/\s+/g, " ")
      .trim();
  }

  function firstText(element, selectors) {
    for (var index = 0; index < selectors.length; index += 1) {
      var node = element.querySelector(selectors[index]);
      var text = node ? compactText(node.textContent) : "";
      if (text) return text;
    }

    return "";
  }

  function pageOutlineTitle(element) {
    return (
      compactText(element.getAttribute("data-outline-label")) ||
      firstText(element, [".hero-title", ".section-title", ".error-title", "summary > span", "h1", "h2"]) ||
      compactText(element.getAttribute("aria-label")) ||
      firstText(element, ["strong"])
    );
  }

  function pageOutlineIdBase(title, index) {
    var pageName = window.location.pathname.replace(/[^a-zA-Z0-9]+/g, "-").replace(/^-|-$/g, "") || "dashboard";
    var slug =
      title
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-|-$/g, "")
        .slice(0, 36) || "section";

    return "outline-" + pageName + "-" + slug + "-" + (index + 1);
  }

  function ensurePageOutlineId(element, title, index) {
    if (element.id) return element.id;

    var base = pageOutlineIdBase(title, index);
    var candidate = base;
    var suffix = 2;

    while (document.getElementById(candidate) && document.getElementById(candidate) !== element) {
      candidate = base + "-" + suffix;
      suffix += 1;
    }

    element.id = candidate;
    element.setAttribute("data-outline-generated-id", "true");
    return candidate;
  }

  function isPageOutlineTarget(element) {
    if (!element || !element.matches) return false;
    if (element.closest(".page-outline")) return false;
    if (element.hidden) return false;
    return true;
  }

  function pageOutlineTargets() {
    var root = document.querySelector(".dashboard-shell");
    if (!root) return [];

    return Array.prototype.slice
      .call(root.querySelectorAll(pageOutlineTargetSelector))
      .filter(isPageOutlineTarget)
      .map(function (element, index) {
        var title = pageOutlineTitle(element);
        if (!title) return null;

        return {
          id: ensurePageOutlineId(element, title, index),
          title: title,
          target: element
        };
      })
      .filter(Boolean);
  }

  function setActivePageOutline(id) {
    var outline = document.querySelector("[data-page-outline]");
    if (!outline || !id) return;

    outline.querySelectorAll(".page-outline-link").forEach(function (link) {
      var active = link.getAttribute("data-outline-target") === id;
      link.classList.toggle("page-outline-link-active", active);

      if (active) {
        link.setAttribute("aria-current", "location");
      } else {
        link.removeAttribute("aria-current");
      }
    });
  }

  function updatePageOutlineFromViewport() {
    if (pageOutlineEntries.length === 0) return;

    var focusLine = Math.max(120, window.innerHeight * 0.34);
    var current = null;
    var next = null;

    pageOutlineEntries.forEach(function (entry) {
      var rect = entry.target.getBoundingClientRect();

      if (rect.top <= focusLine && rect.bottom > 80) {
        current = entry;
      }

      if (!next && rect.top > focusLine) {
        next = entry;
      }
    });

    setActivePageOutline((current || next || pageOutlineEntries[pageOutlineEntries.length - 1]).id);
  }

  function observePageOutlineTargets() {
    if (pageOutlineObserver) {
      pageOutlineObserver.disconnect();
      pageOutlineObserver = null;
    }

    if (!("IntersectionObserver" in window)) {
      updatePageOutlineFromViewport();
      return;
    }

    pageOutlineObserver = new window.IntersectionObserver(
      function () {
        updatePageOutlineFromViewport();
      },
      {
        rootMargin: "-18% 0px -58% 0px",
        threshold: [0, 0.08, 0.2, 0.55, 1]
      }
    );

    pageOutlineEntries.forEach(function (entry) {
      pageOutlineObserver.observe(entry.target);
    });

    window.setTimeout(updatePageOutlineFromViewport, 0);
  }

  function buildPageOutline() {
    var outline = document.querySelector("[data-page-outline]");
    var list = document.querySelector("[data-page-outline-list]");

    if (!outline || !list) return;

    pageOutlineEntries = pageOutlineTargets();
    list.replaceChildren();

    if (pageOutlineEntries.length < 2) {
      outline.hidden = true;
      if (pageOutlineObserver) pageOutlineObserver.disconnect();
      return;
    }

    pageOutlineEntries.forEach(function (entry) {
      var link = document.createElement("a");
      link.className = "page-outline-link";
      link.href = "#" + encodeURIComponent(entry.id);
      link.textContent = entry.title;
      link.setAttribute("data-outline-target", entry.id);
      list.appendChild(link);
    });

    outline.hidden = false;
    observePageOutlineTargets();
  }

  function queuePageOutlineBuild() {
    if (pageOutlineQueued) return;

    pageOutlineQueued = true;
    window.setTimeout(function () {
      pageOutlineQueued = false;
      buildPageOutline();
    }, 0);
  }

  function mutationInsidePageOutline(mutation) {
    var outline = document.querySelector("[data-page-outline]");
    return outline && outline.contains(mutation.target);
  }

  function watchPageOutlineTargets() {
    if (!window.MutationObserver || !document.body || pageOutlineMutationObserver) return;

    pageOutlineMutationObserver = new window.MutationObserver(function (mutations) {
      var outlineOnly = mutations.every(mutationInsidePageOutline);
      if (!outlineOnly) queuePageOutlineBuild();
    });

    pageOutlineMutationObserver.observe(document.body, {childList: true, subtree: true});
  }

  function handlePageOutlineClick(event) {
    var link = event.target.closest(".page-outline-link[data-outline-target]");
    if (!link) return;

    var targetId = link.getAttribute("data-outline-target");
    if (!targetId || !elementById(targetId)) return;

    event.preventDefault();

    if (window.history && window.history.replaceState) {
      window.history.replaceState(null, "", "#" + encodeURIComponent(targetId));
    } else {
      window.location.hash = targetId;
    }

    focusTargetById(targetId);
    setActivePageOutline(targetId);
  }

  function fragmentFromHref(href) {
    if (!href) return null;

    var hashIndex = href.indexOf("#");
    if (hashIndex < 0 || hashIndex === href.length - 1) return null;

    return decodeURIComponent(href.slice(hashIndex + 1));
  }

  function elementById(id) {
    if (!id) return null;
    return document.getElementById(id);
  }

  function openDetailsById(id) {
    var details = elementById(id);
    if (!details || details.tagName.toLowerCase() !== "details") return null;

    details.open = true;
    return details;
  }

  function openContainingDetails(target) {
    if (!target || !target.closest) return;

    var details = target.closest("details");
    if (details) details.open = true;
  }

  function focusTargetById(id) {
    var target = elementById(id);
    if (!target) return;

    openContainingDetails(target);

    if (!target.hasAttribute("tabindex")) {
      target.setAttribute("tabindex", "-1");
    }

    try {
      target.focus({preventScroll: true});
    } catch (_error) {
      target.focus();
    }

    if (typeof target.scrollIntoView === "function") {
      target.scrollIntoView({block: "center", inline: "nearest"});
    }
  }

  function openDetailsForCurrentHash() {
    var targetId = window.location.hash ? decodeURIComponent(window.location.hash.slice(1)) : "";
    var target = elementById(targetId);

    if (!target) return;

    openContainingDetails(target);

    if (target.closest && target.closest("#hub-project-details")) {
      window.setTimeout(function () {
        focusTargetById(targetId);
      }, 0);
    }
  }

  function handleDetailsAnchorClick(event) {
    var trigger = event.target.closest("[data-open-details], [data-scroll-target]");
    if (!trigger) return;

    var detailsId = trigger.getAttribute("data-open-details");
    var focusTarget = trigger.getAttribute("data-focus-target") || trigger.getAttribute("data-scroll-target") || fragmentFromHref(trigger.getAttribute("href"));

    if (detailsId) {
      openDetailsById(detailsId);
    }

    if (focusTarget) {
      window.setTimeout(function () {
        focusTargetById(focusTarget);
      }, 0);
    }
  }

  function resetCopyButton(button, delay) {
    clearTimeout(button.__copyTimer);
    button.__copyTimer = window.setTimeout(function () {
      button.textContent = button.getAttribute("data-label") || "复制 ID";
    }, delay);
  }

  function setCopyButtonState(button, text, delay) {
    button.textContent = text;
    announceCopyButtonState(button, text);
    resetCopyButton(button, delay);
  }

  function announceCopyButtonState(button, text) {
    var status = document.getElementById("copy-status");
    if (!status) return;

    var label = button.getAttribute("data-copy-label") || "当前 Issue";
    status.textContent = label + "：" + text;
  }

  function copyTextFromButton(button) {
    var value = button.getAttribute("data-copy") || "";

    if (!navigator.clipboard || !navigator.clipboard.writeText) {
      setCopyButtonState(button, "复制失败", 1600);
      return;
    }

    navigator.clipboard
      .writeText(value)
      .then(function () {
        setCopyButtonState(button, "已复制", 1200);
      })
      .catch(function () {
        setCopyButtonState(button, "复制失败", 1600);
      });
  }

  document.addEventListener("click", function (event) {
    var button = event.target.closest(".copy-button[data-copy]");
    if (!button) return;

    event.preventDefault();
    copyTextFromButton(button);
  });

  document.addEventListener("click", handleDetailsAnchorClick);
  document.addEventListener("click", handlePageOutlineClick);
  window.addEventListener("hashchange", openDetailsForCurrentHash);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      startWorkflowMermaidRendering();
      initializeRevealObserver();
      watchRevealTargets();
      openDetailsForCurrentHash();
      buildPageOutline();
      watchPageOutlineTargets();
    });
  } else {
    startWorkflowMermaidRendering();
    initializeRevealObserver();
    watchRevealTargets();
    openDetailsForCurrentHash();
    buildPageOutline();
    watchPageOutlineTargets();
  }

  window.SymphonyDashboardHooks = Object.assign(window.SymphonyDashboardHooks || {}, {
    WorkflowMermaid: {
      mounted: function () {
        var hook = this;

        hook.el.__workflowPushStage = function (stageId) {
          hook.pushEvent("select_stage", {stage: stageId});
        };

        renderWorkflowMermaid(hook.el);
      },

      updated: function () {
        renderWorkflowMermaid(this.el);
      },

      destroyed: function () {
        delete this.el.__workflowPushStage;
      }
    }
  });
})();
