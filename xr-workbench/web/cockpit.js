const element = (id) => document.getElementById(id);
const isObject = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const probability = (value) =>
  typeof value === "number" &&
  Number.isFinite(value) &&
  value >= 0 &&
  value <= 1;
const percent = (value) => `${(value * 100).toFixed(1)}%`;

export function createCockpit({ api, flow, panel }) {
  let timer,
    mode = "ready",
    input = [],
    output = [],
    inputIndex = 0,
    outputIndex = 0,
    liveSignature = "";
  const inputNode = element("agent-input-stream");
  const outputNode = element("agent-output-stream");
  function event(message) {
    const trace = element("agent-events");
    const row = document.createElement("li");
    row.textContent = message;
    trace.append(row);
    while (trace.children.length > 8) trace.firstElementChild.remove();
  }

  function phase(value) {
    element("agent-phase").textContent = value;
    element("hud-agent").textContent = value;
    const latest =
      mode === "live"
        ? outputNode.textContent
        : outputNode.textContent || inputNode.textContent;
    panel.lines = [
      "AGENT COCKPIT",
      value,
      `${inputIndex} in · ${outputIndex} out`,
      latest.slice(-95) || "Waiting for an exchange",
    ];
    panel.metrics = {
      state: value,
      input: `${inputIndex} / ${input.length}`,
      output: `${outputIndex} / ${output.length}`,
      preview: latest.slice(-72) || "Ready to inspect the exchange.",
    };
    panel.flowStatus =
      mode === "replay" && inputIndex < input.length
        ? `PUSH → ${inputIndex}/${input.length} request chunks`
        : `← PULL · ${outputIndex} output chunks`;
    flow.refresh();
  }
  function stop() {
    clearInterval(timer);
    timer = undefined;
    element("agent-pause").disabled = true;
  }
  function counters() {
    element("agent-input-count").textContent =
      `${inputIndex} / ${input.length} chunks received`;
    element("agent-output-count").textContent =
      `${outputIndex} / ${output.length} chunks emitted`;
  }
  function chunks(value) {
    return value.match(/\S+\s*/g) || [];
  }
  function replay() {
    const request = element("agent-prompt").value.trim();
    if (!request || request.length > 400) {
      flow.notice("Enter a request under 400 characters.");
      return;
    }
    stop();
    mode = "replay";
    input = chunks(request);
    output = chunks(
      `I received: “${request}”\n\nI would define an observable result, build a deterministic fixture, run the evaluation, and retain a trace that can be replayed. This response is a demo fixture; no model or tools were called.`,
    );
    inputIndex = 0;
    outputIndex = 0;
    inputNode.textContent = "";
    outputNode.textContent = "";
    counters();
    element("agent-events").replaceChildren();
    event("Request pushed into replay fixture.");
    element("agent-pause").disabled = false;
    flow.update(
      "push",
      "Agent request replay",
      "fixture input entering context",
    );
    phase("READING INPUT · fixture");
    timer = setInterval(() => {
      if (inputIndex < input.length) {
        inputNode.append(document.createTextNode(input[inputIndex++]));
        phase("READING INPUT · fixture");
      } else if (outputIndex < output.length) {
        if (outputIndex === 0) {
          event("Input complete; fixture output started pulling back.");
          flow.update(
            "pull",
            "Agent fixture",
            "deterministic response streaming back",
          );
        }
        outputNode.append(document.createTextNode(output[outputIndex++]));
        phase("EMITTING OUTPUT · fixture");
      } else {
        stop();
        phase("COMPLETE · fixture, no model called");
        event("Fixture complete. No model or tools were called.");
      }
      counters();
    }, 100);
  }
  function live(job) {
    stop();
    mode = "live";
    if (!job) {
      flow.notice("Select or run a workspace command first.");
      return;
    }
    liveSignature = `${job.id}:${job.state}:${job.output.length}`;
    if (
      !element("agent-events").lastElementChild?.textContent?.includes(
        `${job.action} · ${job.state}`,
      )
    )
      event(`Pulled ${job.action} · ${job.state} from workspace bridge.`);
    input = chunks(job.command.join(" "));
    inputIndex = input.length;
    output = chunks(job.output || "");
    outputIndex = output.length;
    inputNode.textContent = job.command.join(" ");
    outputNode.textContent = job.output || "Waiting for command output…";
    counters();
    phase(`${job.action.toUpperCase()} · ${job.state} · workspace command`);
    flow.update(
      "pull",
      `${job.action} · ${job.state}`,
      "workspace output visible in cockpit",
    );
  }
  function sync(job) {
    if (
      mode === "live" &&
      job &&
      `${job.id}:${job.state}:${job.output.length}` !== liveSignature
    )
      live(job);
  }

  function item(label, value) {
    const row = document.createElement("div");
    row.className = "capability-row";
    const title = document.createElement("strong");
    title.textContent = label;
    const content = document.createElement("span");
    content.textContent = value;
    row.append(title, content);
    return row;
  }
  async function loadCapabilities() {
    try {
      const data = await api("capabilities");
      element("capability-hud").replaceChildren(
        ...data.categories.map((category) =>
          item(
            category.title,
            category.items.length
              ? category.items.join(" · ")
              : category.note || "None configured in repository",
          ),
        ),
      );
      element("capability-source").textContent = data.source;
    } catch (error) {
      element("capability-hud").textContent =
        `Capability inventory unavailable: ${error.message}`;
    }
  }

  function distribution(map, legend) {
    const group = document.createElement("div");
    group.className = "prob-list";
    if (!isObject(map)) return group;
    for (const [key, amount] of Object.entries(map)) {
      if (!probability(amount)) continue;
      const row = document.createElement("div");
      row.className = "prob-row";
      const label = document.createElement("div");
      label.className = "prob-label";
      label.textContent = `${key}${typeof legend?.[key] === "string" ? ` · ${legend[key]}` : ""} · ${percent(amount)}`;
      const track = document.createElement("div");
      track.className = "prob-track";
      const bar = document.createElement("span");
      bar.style.width = percent(amount);
      track.append(bar);
      row.append(label, track);
      group.append(row);
    }
    return group;
  }
  function inspect() {
    const target = element("jev-results");
    target.replaceChildren();
    try {
      const source = element("jev-json").value;
      if (!source.trim())
        throw new Error("Paste a Jev response JSON object first.");
      if (source.length > 65536)
        throw new Error("Response JSON is too large (64 KB maximum).");
      const value = JSON.parse(source);
      if (
        !isObject(value) ||
        !isObject(value.answers) ||
        !Object.keys(value.answers).length
      )
        throw new Error(
          "Expected a Jev response object with a nonempty answers map.",
        );
      const answers = Object.entries(value.answers);
      if (answers.length > 100)
        throw new Error("Limit the response to 100 answers.");
      if (answers.some(([, answer]) => !isObject(answer)))
        throw new Error("Each answer must be an object with a type.");
      const summary = document.createElement("p");
      summary.className = "jev-summary";
      const usage = isObject(value.usage) ? value.usage : {};
      const count = `${answers.length} typed ${answers.length === 1 ? "answer" : "answers"}`;
      const model =
        typeof value.model === "string" ? value.model : "not provided";
      summary.textContent = `${count} · Model: ${model}${Number.isFinite(usage.input_tokens) && Number.isFinite(usage.output_tokens) ? ` · ${usage.input_tokens} input / ${usage.output_tokens} output tokens` : ""}`;
      target.append(summary);
      for (const [key, answer] of answers) {
        const card = document.createElement("article");
        card.className = "jev-card";
        const heading = document.createElement("div");
        heading.className = "jev-card-head";
        const title = document.createElement("strong");
        title.textContent = key;
        const type = document.createElement("span");
        type.className = "type-pill";
        type.textContent = String(answer.type ?? "unknown");
        heading.append(title, type);
        card.append(heading);
        const result = document.createElement("div");
        result.className = "jev-value";
        if (answer.type === "choice" && typeof answer.choice === "string") {
          result.textContent = answer.choice;
          card.append(result, distribution(answer.probabilities));
        } else if (answer.type === "noul" && probability(answer.noul)) {
          result.textContent = `${percent(answer.noul)} probability of yes`;
          card.append(result, distribution({ Yes: answer.noul }));
        } else if (
          answer.type === "score" &&
          typeof answer.score === "number" &&
          Number.isFinite(answer.score)
        ) {
          result.textContent = `${answer.score} weighted score`;
          card.append(
            result,
            distribution(answer.probabilities, answer.legend),
          );
        } else {
          result.textContent =
            "Answer type not recognized. Original JSON remains in the input.";
          card.append(result);
        }
        if (probability(answer.confidence)) {
          const confidence = document.createElement("small");
          confidence.textContent = `Confidence ${percent(answer.confidence)}`;
          card.append(confidence);
        }
        target.append(card);
      }
      const note = document.createElement("p");
      note.className = "muted";
      note.textContent =
        "Probabilities are shown as returned. Confidence is not a correctness guarantee.";
      target.append(note);
      mode = "jev";
      panel.lines = ["TYPED OUTPUT", count, `Model ${model}`];
      panel.metrics = {
        state: "JEV INSPECTED",
        input: "JSON",
        output: count,
        preview: `Model ${model}`,
      };
      panel.flowStatus = `← PULL · ${count}`;
      flow.refresh();
      event(`Inspected Jev response: ${count}.`);
      flow.update("pull", "Jev output inspected", count);
    } catch (error) {
      const message = document.createElement("p");
      message.className = "jev-error";
      message.setAttribute("role", "alert");
      message.textContent =
        error instanceof SyntaxError
          ? "Invalid JSON. Check the response syntax and try again."
          : error.message;
      target.append(message);
    }
  }
  element("agent-replay").onclick = replay;
  element("agent-live").onclick = () => live(flow.selectedJob());
  element("agent-pause").onclick = () => {
    stop();
    phase("PAUSED · fixture");
  };
  element("jev-inspect").onclick = inspect;
  element("jev-example").onclick = () => {
    element("jev-json").value = JSON.stringify(
      {
        model: "example-fixture",
        usage: { input_tokens: 18, output_tokens: 12 },
        answers: {
          direction: {
            type: "choice",
            choice: "pull feedback",
            probabilities: { "pull feedback": 0.78, "push revision": 0.22 },
            confidence: 0.78,
          },
          readiness: { type: "noul", noul: 0.64 },
        },
      },
      null,
      2,
    );
    inspect();
  };
  return { replay, live, sync, inspect, loadCapabilities };
}
