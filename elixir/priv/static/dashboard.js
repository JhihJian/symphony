(function () {
  var mermaidInitialized = false;
  var renderSequence = 0;

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
        primaryTextColor: "#202123",
        primaryBorderColor: "#d9d9e3",
        lineColor: "#7c8597",
        fontSize: "16px",
        fontFamily: "Sohne, SF Pro Text, Helvetica Neue, Segoe UI, sans-serif"
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
  window.addEventListener("hashchange", openDetailsForCurrentHash);

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () {
      startWorkflowMermaidRendering();
      openDetailsForCurrentHash();
    });
  } else {
    startWorkflowMermaidRendering();
    openDetailsForCurrentHash();
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
