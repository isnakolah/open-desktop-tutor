import assert from "node:assert/strict";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import plugin from "../index.mjs";
import {handleTutorNodeHostCommand, invokeTutorHost} from "../src/node-host.mjs";
import {buildTutorEnvelope, findForbiddenCoordinatePath, parsePluginConfig} from "../src/protocol.mjs";


function fakeApi(overrides = {}) {
  const registrations = {
    tools: [],
    hooks: new Map(),
    nodeCommands: [],
    nodePolicies: [],
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
  };
  return {api, registrations};
}


test("gateway role registers semantic tools and policy without a Mac node handler", () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  assert.deepEqual(
    registrations.tools.map((tool) => tool.name).sort(),
    ["tutor_observe", "tutor_point", "tutor_propose_action", "tutor_retrieve", "tutor_verify"],
  );
  assert.equal(registrations.nodeCommands.length, 0);
  assert.deepEqual(registrations.nodePolicies[0].defaultPlatforms, ["macos"]);
  assert.equal(typeof registrations.hooks.get("before_tool_call"), "function");
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
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].nodeId, "paired-mac");
  assert.equal(calls[0].command, "desktop-tutor.host");
  assert.equal(calls[0].params.operation, "observe");
  assert.equal(calls[0].params.session_id, "session-1234");
  assert.equal(result.details.state.mode, "OBJECT");
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
        semantic_target: "blender.ui.properties.modifiers_tab",
        snapshot_id: "snapshot-1",
        x: 847,
        y: 291,
      }),
    /raw coordinate field x is forbidden/,
  );
});


test("normalised vision hints are accepted only by point, and only within 0..1", () => {
  const base = {
    session_id: "session-1234",
    semantic_target: "blender.ui.properties.modifiers_tab",
    snapshot_id: "snapshot-1",
  };
  const hint = {description: "wrench icon", region: {x: 0.82, y: 0.2, width: 0.04, height: 0.03}};

  // Accepted on point, and the raw-coordinate scan still runs on everything else.
  const envelope = buildTutorEnvelope("tutor_point", {...base, target_hint: hint});
  assert.deepEqual(envelope.payload.target_hint, hint);

  // A hint can never authorise an action.
  assert.throws(
    () =>
      buildTutorEnvelope("tutor_propose_action", {
        ...base,
        action: "click",
        expected_state: {},
        rationale: "open modifiers",
        target_hint: hint,
      }),
    /only by tutor_point/,
  );

  // Pixel-shaped values masquerading as a hint are rejected.
  for (const region of [
    {x: 1420, y: 377, width: 24, height: 24},
    {x: 0.5, y: 0.5, width: 0.9, height: 0.9},
    {x: -0.1, y: 0.2, width: 0.1, height: 0.1},
    {x: 0.1, y: 0.2, width: 0, height: 0.1},
  ]) {
    assert.throws(
      () => buildTutorEnvelope("tutor_point", {...base, target_hint: {description: "d", region}}),
      /target_hint\.region/,
      `region should be rejected: ${JSON.stringify(region)}`,
    );
  }

  // The exemption is scoped to target_hint; coordinates elsewhere still fail.
  assert.throws(
    () => buildTutorEnvelope("tutor_point", {...base, target_hint: hint, x: 847, y: 291}),
    /raw coordinate field x is forbidden/,
  );
});

test("authored target descriptors pass the coordinate rejector unchanged", () => {
  const descriptor = {
    semantic_id: "blender.ui.properties.modifiers_tab",
    bundle_ids: ["org.blenderfoundation.blender"],
    resolve: {
      bridge: {selector: {editor_type: "PROPERTIES", context: "MODIFIER"}},
      accessibility: {candidates: [{role: "AXRadioButton", label_regex: "(?i)modifier"}]},
      visual: {icon: "wrench"},
    },
    disambiguate: {expected_neighbors: ["object_data", "particles"]},
    minimum_confidence: {point: 0.72, act: 0.92},
  };
  const envelope = buildTutorEnvelope("tutor_point", {
    session_id: "session-1234",
    semantic_target: "blender.ui.properties.modifiers_tab",
    snapshot_id: "snapshot-1",
    target_descriptor: descriptor,
  });
  assert.deepEqual(envelope.payload.target_descriptor, descriptor);
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
        semantic_target: "blender.ui.properties.modifiers_tab",
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
      expectation_id: "lesson.step.success",
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
    buildTutorEnvelope("tutor_verify", {session_id: "session-1234", expectation_id: "lesson.step.success"}),
    {socketPath: missingSocket, timeoutMs: 500},
  );
  assert.deepEqual(response, {
    ok: false,
    code: "TUTOR_HOST_UNAVAILABLE",
    message: "Calla TutorHost is not running or is not accepting local requests.",
  });
});
