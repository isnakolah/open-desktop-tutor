import {buildTutorEnvelope, unwrapNodePayload} from "./protocol.mjs";
import {requireCanonicalDescriptor, requirePackAuthorizedAction, retrieveLocalPacks} from "./local-retrieval.mjs";

const baseSessionProperty = {
  session_id: {type: "string", minLength: 8, description: "Opaque TutorHost teaching session id."},
};

/// Which applications this lesson is allowed to look at.
///
/// Without this the Mac falls back to its built-in default and only Blender can
/// ever be taught, which defeats the point of a path that needs no authored
/// pack. The Mac still requires one of these to be the focused window; naming an
/// application here grants no access to it.
const allowedBundleIDsProperty = {
  allowed_bundle_ids: {
    type: "array",
    items: {type: "string", minLength: 1, maxLength: 255},
    maxItems: 8,
    description: "Bundle ids this lesson may observe, e.g. [\"org.blenderfoundation.blender\"].",
  },
};

const definitions = {
  tutor_observe: {
    label: "Tutor Observe",
    description: [
      "START HERE whenever the learner asks how to do something on their Mac.",
      "Calla teaches by pointing at their actual screen, not by writing instructions:",
      "answering from memory is the one wrong move, because the learner is looking at",
      "their own window and cannot see anything you type.",
      "",
      "The loop: tutor_observe with include_capture true and allowed_bundle_ids naming",
      "the application, read the returned image, then tutor_guide at a region of it.",
      "guide waits for the learner and hands back next_observation, a fresh image, so",
      "every step after the first is one call.",
      "",
      "Returns only the focused allowlisted window as an in-memory JPEG bound to",
      "snapshot_id; never request a display capture.",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id"],
      properties: {
        ...baseSessionProperty,
        ...allowedBundleIDsProperty,
        requested_fields: {type: "array", items: {type: "string"}, maxItems: 32},
        include_capture: {type: "boolean", default: false},
      },
    },
  },
  tutor_retrieve: {
    label: "Tutor Retrieve",
    description: "Retrieve version-matched App Pack entities from the user's TutorHost knowledge store. Preserve a returned target_descriptor or detector_descriptor verbatim for later calls.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "query", "application"],
      properties: {
        ...baseSessionProperty,
        query: {type: "string", minLength: 1, maxLength: 1000},
        application: {
          type: "object",
          additionalProperties: false,
          required: ["bundle_id", "version"],
          properties: {
            bundle_id: {type: "string", minLength: 1, maxLength: 255},
            version: {type: "string", minLength: 1, maxLength: 80},
            platform: {enum: ["macos", "windows", "linux"], default: "macos"},
            locale: {type: "string", minLength: 2, maxLength: 20},
          },
        },
        entity_types: {type: "array", items: {type: "string"}, maxItems: 16},
        limit: {type: "integer", minimum: 1, maximum: 20, default: 5},
      },
    },
  },
  tutor_plan: {
    label: "Tutor Plan",
    description: [
      "Lay out the whole route before you start pointing, then keep it current.",
      "The learner sees the steps listed in the tooltip with the current one lit,",
      "so they know how far in they are and what is coming instead of being handed",
      "one instruction at a time.",
      "",
      "Short titles, a few words each — \"Delete the cube\", not a sentence. This is",
      "provisional: when the screen turns out differently from what you expected,",
      "call it again with a corrected list rather than forcing the old one.",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "steps"],
      properties: {
        ...baseSessionProperty,
        steps: {
          type: "array",
          minItems: 2,
          maxItems: 12,
          items: {type: "string", minLength: 1, maxLength: 60},
          description: "Short titles for each step, in order.",
        },
        index: {type: "integer", minimum: 0, description: "Which step the lesson is on now."},
      },
    },
  },
  tutor_guide: {
    label: "Tutor Guide",
    description: [
      "Move Calla's cursor to a region you read off the window capture and say what to",
      "do there. This is how the learner is taught: the text appears in a tooltip on",
      "their screen, next to the control. Prefer this over describing anything in chat.",
      "",
      "region is normalized to the observed window and should be tight around the",
      "control — a few percent per side lands on a button, a quarter of the window",
      "lands on nothing. Keep text to one instruction, under about 140 characters.",
      "",
      "Leave wait_for_change and capture_after_change true. The call then waits for the",
      "learner to act and returns next_observation with a fresh image, so you can guide",
      "the next step straight from it without calling tutor_observe again.",
      "",
      "This never clicks. Ask the learner to do it; you point.",
    ].join(" "),
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "snapshot_id", "region", "text"],
      properties: {
        ...baseSessionProperty,
        ...allowedBundleIDsProperty,
        snapshot_id: {type: "string", minLength: 1},
        region: {
          type: "object",
          additionalProperties: false,
          required: ["left", "top", "width", "height"],
          properties: {
            left: {type: "number", minimum: 0, maximum: 1},
            top: {type: "number", minimum: 0, maximum: 1},
            width: {type: "number", exclusiveMinimum: 0, maximum: 1},
            height: {type: "number", exclusiveMinimum: 0, maximum: 1},
          },
        },
        step: {type: "string", maxLength: 60, description: "Short progress label, for example \"Step 2 of 4\"."},
        text: {type: "string", minLength: 1, maxLength: 240, description: "One instruction, in the learner's words."},
        status: {type: "string", maxLength: 80},
        step_index: {type: "integer", minimum: 0, description: "Which planned step this is, so the list keeps up."},
        wait_for_change: {
          type: "boolean",
          default: false,
          description: "Watch for the screen to change instead of waiting to be told. Off by default: the learner says when they are done, which is more reliable than guessing from pixels and does not hurry them.",
        },
        timeout_seconds: {type: "number", minimum: 1, maximum: 25, default: 15},
        capture_after_change: {
          type: "boolean",
          default: true,
          description: "Return a fresh capture once the learner acts, so the next step needs no separate tutor_observe. Leave true.",
        },
      },
    },
  },
  tutor_await_change: {
    label: "Tutor Await Change",
    description:
      "Wait until the learner actually does something in the window, then return. This is how a lesson advances: guide a step, wait here, observe again, guide the next one. Returns changed false if the wait ran out, so you can re-word the step or keep waiting.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "snapshot_id"],
      properties: {
        ...baseSessionProperty,
        ...allowedBundleIDsProperty,
        snapshot_id: {type: "string", minLength: 1},
        timeout_seconds: {type: "number", minimum: 1, maximum: 25, default: 15},
        sensitivity: {
          type: "number",
          minimum: 0.005,
          maximum: 0.5,
          default: 0.02,
          description: "How much of the window must differ to count as a change. Lower notices smaller edits.",
        },
      },
    },
  },
  tutor_narrate: {
    label: "Tutor Narrate",
    description:
      "Re-word the tooltip without moving the cursor. Use it to add a beat about the control you already pointed at, or to say you are still working something out.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "text"],
      properties: {
        ...baseSessionProperty,
        step: {type: "string", maxLength: 60},
        text: {type: "string", minLength: 1, maxLength: 240},
        status: {type: "string", maxLength: 80},
        thinking: {type: "boolean", default: false},
      },
    },
  },
  tutor_point: {
    label: "Tutor Point",
    description: "Point the distinct AI cursor at a freshly resolved canonical target_descriptor without moving the system cursor. After capture, a vision model may provide only target_hint.region normalized to the focused window; it is a local search prior, not authority.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "target_descriptor", "snapshot_id"],
      properties: {
        ...baseSessionProperty,
        target_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
        target_hint: {
          type: "object",
          additionalProperties: false,
          required: ["region"],
          properties: {
            region: {
              type: "object",
              additionalProperties: false,
              required: ["left", "top", "width", "height"],
              properties: {
                left: {type: "number", minimum: 0, maximum: 1},
                top: {type: "number", minimum: 0, maximum: 1},
                width: {type: "number", exclusiveMinimum: 0, maximum: 1},
                height: {type: "number", exclusiveMinimum: 0, maximum: 1},
              },
            },
          },
        },
        label: {type: "string", maxLength: 120},
      },
    },
  },
  tutor_propose_action: {
    label: "Tutor Propose Action",
    description: "Propose one bounded semantic action using the same canonical target_descriptor and a canonical expected_state detector. Never accepts target_hint or raw coordinates; TutorHost requires independent local evidence and one-shot approval.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "action", "target_descriptor", "snapshot_id", "expected_state", "rationale"],
      properties: {
        ...baseSessionProperty,
        action: {enum: ["move_cursor", "click", "scroll", "keyboard_shortcut", "type_text"]},
        target_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
        expected_state: {type: "object"},
        rationale: {type: "string", minLength: 1, maxLength: 500},
        value: {type: "string", maxLength: 2000},
      },
    },
  },
  tutor_verify: {
    label: "Tutor Verify",
    description: "Evaluate a canonical detector_descriptor against a freshly locally resolved canonical target_descriptor.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["session_id", "target_descriptor", "detector_descriptor", "snapshot_id"],
      properties: {
        ...baseSessionProperty,
        target_descriptor: {type: "object"},
        detector_descriptor: {type: "object"},
        snapshot_id: {type: "string", minLength: 1},
      },
    },
  },
};

function jsonResult(payload) {
  return {
    content: [{type: "text", text: JSON.stringify(payload, null, 2)}],
    details: payload,
  };
}

/**
 * An observation the model can actually look at.
 *
 * The window JPEG has to reach the model as an image block. Serialised into the
 * JSON text it is both invisible to vision and megabytes of base64 in the
 * transcript, which is why asking for a capture used to accomplish nothing. The
 * base64 is lifted out of the text half entirely and sent once, as an image.
 */
function observationResult(result) {
  // A guide result nests its fresh look under next_observation.
  if (result?.next_observation?.capture || result?.payload?.next_observation?.capture) {
    const holder = result.next_observation ? result : result.payload;
    const nested = observationResult(holder.next_observation);
    const {capture, ...rest} = holder.next_observation;
    const summary = {...result};
    if (result.next_observation) summary.next_observation = {...rest, capture: undefined};
    return {...nested, details: summary,
            content: [{type: "text", text: JSON.stringify(summary, null, 2)},
                      nested.content.find((block) => block.type === "image")].filter(Boolean)};
  }
  // One unwrap may leave either the host's payload or its whole response,
  // depending on how the node transport framed it, so find the capture either
  // way rather than guessing.
  const holder = result?.capture ? result : result?.payload?.capture ? result.payload : null;
  const capture = holder?.capture;
  if (typeof capture?.base64 !== "string") return jsonResult(result);
  const {base64, ...captureMetadata} = capture;
  const redacted = {...holder, capture: {...captureMetadata, delivered_as: "image_content_block"}};
  const summary = holder === result ? redacted : {...result, payload: redacted};
  return {
    content: [
      {type: "text", text: JSON.stringify(summary, null, 2)},
      {type: "image", data: base64, mimeType: capture.mime_type || "image/jpeg"},
    ],
    details: summary,
  };
}

export function createTutorTools(api, config) {
  return Object.entries(definitions).map(([name, definition]) => ({
    name,
    ...definition,
    async execute(_toolCallId, params) {
      const envelope = buildTutorEnvelope(name, params);
      if (name === "tutor_retrieve") {
        return jsonResult(await retrieveLocalPacks(config, envelope.payload));
      }
      if (name === "tutor_point") {
        envelope.payload.target_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
      }
      if (name === "tutor_propose_action") {
        const target = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
        const detector = await requireCanonicalDescriptor(
          config, envelope.payload.expected_state, "detector", "expected_state");
        await requirePackAuthorizedAction(config, envelope.payload.action, target, detector);
        envelope.payload.target_descriptor = target;
        envelope.payload.expected_state = detector;
      }
      if (name === "tutor_verify") {
        envelope.payload.target_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.target_descriptor, "ui_target", "target_descriptor");
        envelope.payload.detector_descriptor = await requireCanonicalDescriptor(
          config, envelope.payload.detector_descriptor, "detector", "detector_descriptor");
      }
      if (!config.nodeId) {
        throw new Error(
          "desktop-tutor is not configured: set plugins.entries.desktop-tutor.config.nodeId to the paired Mac node id",
        );
      }
      // Waiting for the learner is the one call that is meant to take a while,
      // so it gets a transport timeout longer than its own wait rather than
      // being cut off mid-wait by the default.
      const waitSeconds = name === "tutor_await_change" ? Number(envelope.payload.timeout_seconds ?? 15) : 0;
      const timeoutMs = waitSeconds > 0
        ? Math.max(config.timeoutMs, Math.round(waitSeconds * 1000) + 5_000)
        : config.timeoutMs;
      const invoked = await api.runtime.nodes.invoke({
        nodeId: config.nodeId,
        command: "desktop-tutor.host",
        params: envelope,
        timeoutMs,
      });
      const result = unwrapNodePayload(invoked);
      // guide comes back carrying the next observation, so it has an image in
      // it for exactly the same reason observe does.
      if (name === "tutor_observe") return observationResult(result);
      if (name === "tutor_guide") return observationResult(result);
      return jsonResult(result);
    },
  }));
}
