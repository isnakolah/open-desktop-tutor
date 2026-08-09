import {handleTutorNodeHostCommand} from "./src/node-host.mjs";
import {createBeforeToolCallPolicy} from "./src/policy.mjs";
import {NODE_COMMAND, parsePluginConfig} from "./src/protocol.mjs";
import {createTutorTools} from "./src/tools.mjs";

const plugin = {
  id: "desktop-tutor",
  name: "Open Desktop Tutor",
  description: "Teaching-first semantic desktop guidance through a user-owned macOS TutorHost.",

  register(api) {
    const config = parsePluginConfig(api.pluginConfig);

    for (const tool of createTutorTools(api, config)) {
      api.registerTool(tool, {name: tool.name});
    }

    api.on("before_tool_call", createBeforeToolCallPolicy(config));

    api.registerNodeInvokePolicy({
      commands: [NODE_COMMAND],
      defaultPlatforms: ["macos"],
      handle: async (context) => {
        try {
          return await context.invokeNode();
        } catch (error) {
          return {
            ok: false,
            code: "TUTOR_NODE_INVOKE_FAILED",
            message: error instanceof Error ? error.message : String(error),
          };
        }
      },
    });

    api.registerNodeHostCommand({
      command: NODE_COMMAND,
      cap: "desktop-tutor-host",
      dangerous: true,
      handle: async (params) =>
        await handleTutorNodeHostCommand(params, {
          socketPath: config.socketPath || undefined,
          timeoutMs: config.timeoutMs,
        }),
    });
  },
};

export default plugin;
