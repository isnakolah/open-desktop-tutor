import assert from "node:assert/strict";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import plugin from "../index.mjs";
import {invokeTutorHost} from "../src/node-host.mjs";
import {buildTutorEnvelope, findForbiddenCoordinatePath} from "../src/protocol.mjs";


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


test("plugin registers semantic tools, paired node command, and policy", () => {
  const {api, registrations} = fakeApi();
  plugin.register(api);
  assert.deepEqual(
    registrations.tools.map((tool) => tool.name).sort(),
    ["tutor_observe", "tutor_point", "tutor_propose_action", "tutor_retrieve", "tutor_verify"],
  );
  assert.equal(registrations.nodeCommands[0].command, "desktop-tutor.host");
  assert.equal(registrations.nodeCommands[0].dangerous, true);
  assert.deepEqual(registrations.nodePolicies[0].defaultPlatforms, ["macos"]);
  assert.equal(typeof registrations.hooks.get("before_tool_call"), "function");
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


test("hook fails closed without owner identity and requires one-shot approval for actions", async () => {
  const {api, registrations} = fakeApi();
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
