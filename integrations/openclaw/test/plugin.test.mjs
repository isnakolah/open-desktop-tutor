import assert from "node:assert/strict";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import plugin from "../index.mjs";
import {handleTutorNodeHostCommand, invokeTutorHost} from "../src/node-host.mjs";
import {buildTutorEnvelope, findForbiddenCoordinatePath, parsePluginConfig} from "../src/protocol.mjs";

const targetDescriptor = Object.freeze({
  id: "blender.ui.properties.modifiers_tab",
  kind: "ui_target",
  title: "Modifier Properties tab",
  aliases: ["Modifiers", "wrench icon", "Modifier Properties"],
  app_versions: ">=5.2 <5.3",
  source_refs: ["blender-manual"],
  region: "blender.ui.properties_editor",
  resolve: {
    accessibility: {
      candidates: [
        {role: "AXRadioButton", label_matcher: {pattern: "modifier", case_insensitive: true}},
        {role: "AXButton", description_matcher: {pattern: "modifier", case_insensitive: true}},
      ],
    },
    bridge: {selector: {editor_type: "PROPERTIES", context: "MODIFIER"}},
    visual: {icon: "wrench", relative_to: "properties_editor.vertical_context_tabs", constraints: ["visible", "enabled"]},
  },
  neighbor_constraints: {expected: ["object_data", "particles"]},
  minimum_confidence: {point: 0.72, act: 0.92},
  source_file: "ui/modifiers_tab.yaml",
});

const detectorDescriptor = Object.freeze({
  id: "blender.detector.properties_context_is_modifier",
  kind: "detector",
  title: "Modifier Properties context is open",
  app_versions: ">=5.2 <5.3",
  source_refs: ["open-tutor-authored"],
  provider: "accessibility",
  query: {target: "blender.ui.properties.modifiers_tab", attribute: "selected", equals: true},
  source_file: "detectors/core.yaml",
});

function actionLesson() {
  return {
    id: "blender.lesson.bevel_basics",
    kind: "lesson",
    title: "Bevel Basics",
    steps: [{
      target: targetDescriptor.id,
      allowed_assistance: [{action: "click", target: targetDescriptor.id}],
      success: {detector: detectorDescriptor.id},
    }],
  };
}

async function writeDescriptorIndex(stateDirectory) {
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(
    path.join(stateDirectory, "indexes", "blender.json"),
    JSON.stringify({
      format: "calla-local-pack-index",
      format_version: 1,
      pack: {
        id: "org.open-desktop-tutor.blender",
        pack_version: "0.3.0",
        apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3", locales: ["en"]}],
      },
      entities: [targetDescriptor, detectorDescriptor, actionLesson()],
    }),
    "utf8",
  );
}

function fakeApi(overrides = {}) {
  const registrations = {
    tools: [],
    hooks: new Map(),
    nodeCommands: [],
    nodePolicies: [],
    commands: [],
  };
  const api = {
    pluginConfig: {
      nodeId: "paired-mac",
      requireOwnerIdentity: true,
      ...overrides.pluginConfig,
    },
    runtime: {
      nodes: {
        invoke:
          overrides.invoke ??
          (async (request) => ({payload: {ok: true, echoed_operation: request.params.operation}})),
      },
    },
    registerTool(tool) {
      registrations.tools.push(tool);
    },
    on(name, handler) {
      registrations.hooks.set(name, handler);
    },
    registerNodeHostCommand(command) {
      registrations.nodeCommands.push(command);
    },
    registerNodeInvokePolicy(policy) {
      registrations.nodePolicies.push(policy);
    },
    registerCommand(command) {
      registrations.commands.push(command);
    },
  };
  return {api, registrations};
}


test("gateway role registers semantic tools and policy without a Mac node handler", () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  assert.deepEqual(
    registrations.tools.map((tool) => tool.name).sort(),
    [
      "tutor_guide",
      "tutor_narrate",
      "tutor_observe",
      "tutor_point",
      "tutor_propose_action",
      "tutor_retrieve",
      "tutor_verify",
    ],
  );
  assert.equal(registrations.nodeCommands.length, 0);
  assert.deepEqual(registrations.nodePolicies[0].defaultPlatforms, ["macos"]);
  assert.equal(typeof registrations.hooks.get("before_tool_call"), "function");
});

test("the teaching loop reaches the model as prompt guidance", () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  const teach = registrations.commands.find((command) => command.name === "teach");
  assert.ok(teach, "the gateway role registers /teach");

  const guidance = teach.agentPromptGuidance.map((entry) => entry.text).join("\n");
  // Without these the model reads state instead of teaching: it never asks for
  // the capture, and never learns that pointing is available to it.
  assert.match(guidance, /tutor_observe with include_capture true/);
  assert.match(guidance, /tutor_guide with a region normalized to that window/);
  assert.match(guidance, /You cannot click/);
  for (const entry of teach.agentPromptGuidance) {
    assert.ok(entry.surfaces.length > 0, "guidance must not carry an empty surface list");
  }

  const seeded = teach.handler({args: "  bevel a cube  "});
  assert.equal(seeded.continueAgent, true);
  assert.match(seeded.text, /bevel a cube/);
  assert.match(teach.handler({}).text, /focused window/);
});

test("node role exposes only the paired TutorHost command", () => {
  const {api, registrations} = fakeApi({pluginConfig: {role: "node", nodeId: ""}});
  plugin.register(api);
  assert.deepEqual(registrations.tools, []);
  assert.equal(registrations.hooks.size, 0);
  assert.deepEqual(registrations.nodePolicies, []);
  assert.equal(registrations.nodeCommands[0].command, "desktop-tutor.host");
  assert.equal(registrations.nodeCommands[0].dangerous, true);
});

test("both role requires explicit development mode", () => {
  assert.throws(() => parsePluginConfig({role: "both"}), /development-only/);
  assert.equal(parsePluginConfig({role: "both", developmentMode: true}).role, "both");
});


test("observe tool sends a semantic envelope through the configured paired node", async () => {
  const calls = [];
  const {api, registrations} = fakeApi({
    invoke: async (request) => {
      calls.push(request);
      return {payload: {ok: true, state: {mode: "OBJECT"}}};
    },
  });
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_observe");
  const result = await tool.execute("call-1", {
    session_id: "session-1234",
    requested_fields: ["mode", "active_object"],
    include_capture: true,
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].nodeId, "paired-mac");
  assert.equal(calls[0].command, "desktop-tutor.host");
  assert.equal(calls[0].params.operation, "observe");
  assert.equal(calls[0].params.session_id, "session-1234");
  assert.equal(calls[0].params.payload.include_capture, true);
  assert.equal(result.details.state.mode, "OBJECT");
});

test("a requested capture reaches the model as an image, not as base64 text", async () => {
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]).toString("base64");
  const {api, registrations} = fakeApi({
    invoke: async () => ({
      payload: {
        status: "ok",
        snapshot_id: "snapshot-1",
        capture: {snapshot_id: "snapshot-1", mime_type: "image/jpeg", base64: jpeg},
      },
    }),
  });
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_observe");
  const result = await tool.execute("call-1", {session_id: "session-1234", include_capture: true});

  const image = result.content.find((block) => block.type === "image");
  assert.deepEqual(image, {type: "image", data: jpeg, mimeType: "image/jpeg"});
  const text = result.content.find((block) => block.type === "text").text;
  assert.ok(!text.includes(jpeg), "the base64 must not also be pasted into the text block");
  assert.equal(result.details.capture.delivered_as, "image_content_block");
});

test("guide carries one normalized region and never a descriptor", async () => {
  const calls = [];
  const {api, registrations} = fakeApi({
    invoke: async (request) => {
      calls.push(request);
      return {payload: {status: "ok"}};
    },
  });
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_guide");
  await tool.execute("call-1", {
    session_id: "session-1234",
    snapshot_id: "snapshot-1",
    allowed_bundle_ids: ["com.figma.Desktop"],
    region: {left: 0.8, top: 0.2, width: 0.03, height: 0.03},
    step: "Step 1 of 3",
    text: "Open the Modifier Properties tab — the wrench icon.",
  });
  assert.equal(calls[0].params.operation, "guide");
  assert.deepEqual(calls[0].params.payload.region, {left: 0.8, top: 0.2, width: 0.03, height: 0.03});
  // The lesson names its own application; nothing here is Blender-specific.
  assert.deepEqual(calls[0].params.payload.allowed_bundle_ids, ["com.figma.Desktop"]);

  // A pixel rectangle wearing the region's clothes.
  assert.throws(
    () =>
      buildTutorEnvelope("tutor_guide", {
        session_id: "session-1234",
        snapshot_id: "snapshot-1",
        region: {left: 1420, top: 377, width: 24, height: 24},
        text: "click here",
      }),
    /must be in \[0,1\]/,
  );
  // Guiding is the pack-free path; a descriptor there would imply authority it
  // does not have.
  assert.throws(
    () =>
      buildTutorEnvelope("tutor_guide", {
        session_id: "session-1234",
        snapshot_id: "snapshot-1",
        region: {left: 0.1, top: 0.1, width: 0.1, height: 0.1},
        text: "click here",
        target_descriptor: targetDescriptor,
      }),
    /never carries a descriptor/,
  );
});

test("guide and narrate never reach the approval path that actions do", async () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  const policy = registrations.hooks.get("before_tool_call");
  const requester = {senderIsOwner: true};

  const guide = await policy(
    {
      toolName: "tutor_guide",
      params: {
        session_id: "session-1234",
        snapshot_id: "snapshot-1",
        region: {left: 0.5, top: 0.5, width: 0.1, height: 0.1},
        text: "Look here.",
      },
    },
    {requester},
  );
  assert.equal(guide, undefined);

  const narrate = await policy(
    {toolName: "tutor_narrate", params: {session_id: "session-1234", text: "Still working that out."}},
    {requester},
  );
  assert.equal(narrate, undefined);

  const blocked = await policy(
    {
      toolName: "tutor_guide",
      params: {session_id: "session-1234", snapshot_id: "snapshot-1", region: {left: 0.5, top: 0.5, width: 0.9, height: 0.1}, text: "x"},
    },
    {requester},
  );
  assert.equal(blocked.block, true);
});

test("unconfigured plugin loads but tool execution explains the missing paired node", async () => {
  const {api, registrations} = fakeApi({pluginConfig: {nodeId: ""}});
  plugin.register(api);
  const tool = registrations.tools.find((candidate) => candidate.name === "tutor_observe");
  await assert.rejects(
    tool.execute("call-1", {session_id: "session-1234"}),
    /set plugins\.entries\.desktop-tutor\.config\.nodeId/,
  );
});

test("retrieve reads version-matched packs on the gateway and never invokes the Mac", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-retrieval-test-"));
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(
    path.join(stateDirectory, "indexes", "blender.json"),
    JSON.stringify({
      format: "calla-local-pack-index",
      format_version: 1,
      pack: {
        id: "org.open-desktop-tutor.blender",
        pack_version: "0.1.0",
        apps: [{platform: "macos", bundle_ids: ["org.blenderfoundation.blender"], versions: ">=5.2 <5.3", locales: ["en"]}],
      },
      entities: [{id: "blender.lesson.bevel_basics", kind: "lesson", title: "Bevel Basics", text: "Use the bevel modifier.", source_file: "lessons/bevel.yaml"}],
    }),
    "utf8",
  );
  let invokeCount = 0;
  const {api, registrations} = fakeApi({
    pluginConfig: {stateDirectory},
    invoke: async () => {
      invokeCount += 1;
      throw new Error("retrieve must not call the Mac node");
    },
  });
  try {
    plugin.register(api);
    const tool = registrations.tools.find((candidate) => candidate.name === "tutor_retrieve");
    const result = await tool.execute("call-1", {
      session_id: "session-1234",
      query: "bevel modifier",
      application: {bundle_id: "org.blenderfoundation.blender", version: "5.2.0", locale: "en"},
    });
    assert.equal(invokeCount, 0);
    assert.equal(result.details.source, "server-local");
    assert.deepEqual(result.details.results.map((item) => item.id), ["blender.lesson.bevel_basics"]);

    const incompatible = await tool.execute("call-2", {
      session_id: "session-1234",
      query: "bevel",
      application: {bundle_id: "org.blenderfoundation.blender", version: "4.6"},
    });
    assert.deepEqual(incompatible.details.results, []);
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});


test("protocol rejects coordinate-shaped authority", () => {
  assert.equal(findForbiddenCoordinatePath({target: {coordinates: [10, 20]}}), "target.coordinates");
  assert.throws(
    () =>
      buildTutorEnvelope("tutor_point", {
        session_id: "session-1234",
        target_descriptor: targetDescriptor,
        snapshot_id: "snapshot-1",
        x: 847,
        y: 291,
      }),
    /raw coordinate field x is forbidden/,
  );
});

test("Gateway preserves exactly one canonical descriptor and normalized visual hint", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-descriptor-test-"));
  await writeDescriptorIndex(stateDirectory);
  const calls = [];
  const {api, registrations} = fakeApi({
    pluginConfig: {stateDirectory},
    invoke: async (request) => {
      calls.push(request);
      return {payload: {ok: true}};
    },
  });
  try {
    plugin.register(api);
    const point = registrations.tools.find((candidate) => candidate.name === "tutor_point");
    await point.execute("call-1", {
      session_id: "session-1234",
      target_descriptor: structuredClone(targetDescriptor),
      snapshot_id: "snapshot-1",
      target_hint: {region: {left: 0.7, top: 0.1, width: 0.2, height: 0.4}},
    });
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].params.payload.target_descriptor, targetDescriptor);
    assert.deepEqual(calls[0].params.payload.target_hint, {region: {left: 0.7, top: 0.1, width: 0.2, height: 0.4}});
    await assert.rejects(
      point.execute("call-2", {
        session_id: "session-1234",
        target_descriptor: {...targetDescriptor, title: "model replacement"},
        snapshot_id: "snapshot-1",
      }),
      /exactly one installed App-Pack/,
    );
    await assert.rejects(
      point.execute("call-3", {
        session_id: "session-1234",
        target_descriptor: targetDescriptor,
        snapshot_id: "snapshot-1",
        target_hint: {region: {left: 0.9, top: 0, width: 0.2, height: 0.2}},
      }),
      /remain inside the focused window/,
    );
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});

test("actions reject visual hints and require canonical target plus detector descriptors", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-action-descriptor-test-"));
  await writeDescriptorIndex(stateDirectory);
  const calls = [];
  const {api, registrations} = fakeApi({
    pluginConfig: {stateDirectory},
    invoke: async (request) => { calls.push(request); return {payload: {ok: true}}; },
  });
  try {
    plugin.register(api);
    const action = registrations.tools.find((candidate) => candidate.name === "tutor_propose_action");
    await assert.rejects(
      action.execute("call-1", {
        session_id: "session-1234", action: "click", target_descriptor: targetDescriptor, snapshot_id: "snapshot-1",
        expected_state: detectorDescriptor, rationale: "test", target_hint: {region: {left: 0, top: 0, width: 1, height: 1}},
      }),
      /never accepts target_hint/,
    );
    await action.execute("call-2", {
      session_id: "session-1234", action: "click", target_descriptor: structuredClone(targetDescriptor), snapshot_id: "snapshot-1",
      expected_state: structuredClone(detectorDescriptor), rationale: "test",
    });
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].params.payload.expected_state, detectorDescriptor);
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});

test("a malformed installed App-Pack index fails closed", async () => {
  const stateDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "calla-malformed-index-test-"));
  await fs.mkdir(path.join(stateDirectory, "indexes"));
  await fs.writeFile(path.join(stateDirectory, "indexes", "damaged.json"), "{not json", "utf8");
  const {api, registrations} = fakeApi({pluginConfig: {stateDirectory}});
  try {
    plugin.register(api);
    const retrieve = registrations.tools.find((candidate) => candidate.name === "tutor_retrieve");
    await assert.rejects(
      retrieve.execute("call-1", {
        session_id: "session-1234", query: "modifier",
        application: {bundle_id: "org.blenderfoundation.blender", version: "5.2.0", locale: "en"},
      }),
      /index damaged\.json is malformed/,
    );
  } finally {
    await fs.rm(stateDirectory, {recursive: true, force: true});
  }
});


test("optional owner gate and one-shot action approval are independent", async () => {
  const {api, registrations} = fakeApi({pluginConfig: {requireOwnerIdentity: true}});
  plugin.register(api);
  const hook = registrations.hooks.get("before_tool_call");

  const denied = await hook(
    {toolName: "tutor_observe", params: {session_id: "session-1234"}},
    {requester: {senderIsOwner: false}},
  );
  assert.equal(denied.block, true);

  const approval = await hook(
    {
      toolName: "tutor_propose_action",
      params: {
        session_id: "session-1234",
        action: "click",
        target_descriptor: targetDescriptor,
      },
    },
    {requester: {senderIsOwner: true}},
  );
  assert.deepEqual(approval.requireApproval.allowedDecisions, ["allow-once", "deny"]);
  assert.equal(approval.requireApproval.severity, "warning");

  const noOwnerGate = fakeApi({pluginConfig: {requireOwnerIdentity: false}});
  plugin.register(noOwnerGate.api);
  const unrestricted = await noOwnerGate.registrations.hooks.get("before_tool_call")(
    {toolName: "tutor_observe", params: {session_id: "session-1234"}},
    {requester: {senderIsOwner: false}},
  );
  assert.equal(unrestricted, undefined);
});


test("node host IPC accepts one envelope and returns one response", async () => {
  const temporaryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), "open-tutor-node-test-"));
  const socketPath = path.join(temporaryDirectory, "host.sock");
  const server = net.createServer((client) => {
    let input = "";
    client.setEncoding("utf8");
    client.on("data", (chunk) => {
      input += chunk;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.slice(0, input.indexOf("\n")));
      client.end(`${JSON.stringify({ok: true, operation: request.operation})}\n`);
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  try {
    const envelope = buildTutorEnvelope("tutor_verify", {
      session_id: "session-1234",
      target_descriptor: targetDescriptor,
      detector_descriptor: detectorDescriptor,
      snapshot_id: "snapshot-1",
    });
    const response = await invokeTutorHost(envelope, {socketPath, timeoutMs: 2000});
    assert.deepEqual(response, {ok: true, operation: "verify"});
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await fs.rm(temporaryDirectory, {recursive: true, force: true});
  }
});

test("node reports a typed unavailable result before TutorHost starts", async () => {
  const missingSocket = path.join(os.tmpdir(), `calla-missing-${process.pid}-${Date.now()}.sock`);
  const response = await handleTutorNodeHostCommand(
    buildTutorEnvelope("tutor_verify", {
      session_id: "session-1234",
      target_descriptor: targetDescriptor,
      detector_descriptor: detectorDescriptor,
      snapshot_id: "snapshot-1",
    }),
    {socketPath: missingSocket, timeoutMs: 500},
  );
  assert.deepEqual(response, {
    ok: false,
    code: "TUTOR_HOST_UNAVAILABLE",
    message: "Calla TutorHost is not running or is not accepting local requests.",
  });
});
