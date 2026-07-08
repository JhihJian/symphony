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
        output.innerHTML =
          "<div class=\"error-card workflow-mermaid-error\"><h2 class=\"error-title\">Workflow 图渲染失败</h2><p class=\"error-copy\">" +
          String(error && error.message ? error.message : error) +
          "</p></div>";
      });
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

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", startWorkflowMermaidRendering);
  } else {
    startWorkflowMermaidRendering();
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
