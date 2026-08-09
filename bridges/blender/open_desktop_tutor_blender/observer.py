from __future__ import annotations

from typing import Any


MAX_OBJECTS = 100
MAX_MODIFIERS = 50
MAX_AREAS = 32


def _vector(value: Any, length: int) -> list[float] | None:
    if value is None:
        return None
    try:
        return [round(float(value[index]), 6) for index in range(length)]
    except (IndexError, KeyError, TypeError, ValueError):
        axes = ("x", "y", "z", "w")[:length]
        try:
            return [round(float(getattr(value, axis)), 6) for axis in axes]
        except (AttributeError, TypeError, ValueError):
            return None


def _modifier_summary(modifier: Any) -> dict[str, Any]:
    return {
        "name": str(getattr(modifier, "name", "")),
        "type": str(getattr(modifier, "type", "UNKNOWN")),
        "show_viewport": bool(getattr(modifier, "show_viewport", True)),
        "show_render": bool(getattr(modifier, "show_render", True)),
    }


def _object_summary(obj: Any, *, detailed: bool) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "name": str(getattr(obj, "name", "")),
        "type": str(getattr(obj, "type", "UNKNOWN")),
        "selected": bool(obj.select_get()) if callable(getattr(obj, "select_get", None)) else False,
        "visible": bool(obj.visible_get()) if callable(getattr(obj, "visible_get", None)) else True,
    }
    if detailed:
        summary.update(
            {
                "location": _vector(getattr(obj, "location", None), 3),
                "rotation_euler": _vector(getattr(obj, "rotation_euler", None), 3),
                "scale": _vector(getattr(obj, "scale", None), 3),
                "modifiers": [
                    _modifier_summary(modifier)
                    for modifier in list(getattr(obj, "modifiers", ()))[:MAX_MODIFIERS]
                ],
            }
        )
        mesh = getattr(obj, "data", None)
        if summary["type"] == "MESH" and mesh is not None:
            summary["mesh"] = {
                "vertices": len(getattr(mesh, "vertices", ())),
                "edges": len(getattr(mesh, "edges", ())),
                "polygons": len(getattr(mesh, "polygons", ())),
            }
    return summary


def _screen_areas(context: Any) -> tuple[list[dict[str, Any]], list[str]]:
    screen = getattr(context, "screen", None)
    areas: list[dict[str, Any]] = []
    properties_contexts: list[str] = []
    for area in list(getattr(screen, "areas", ()))[:MAX_AREAS]:
        area_type = str(getattr(area, "type", "UNKNOWN"))
        entry: dict[str, Any] = {
            "type": area_type,
            "width": int(getattr(area, "width", 0)),
            "height": int(getattr(area, "height", 0)),
        }
        ui_type = getattr(area, "ui_type", None)
        if ui_type:
            entry["ui_type"] = str(ui_type)
        if area_type == "PROPERTIES":
            spaces = getattr(area, "spaces", None)
            active_space = getattr(spaces, "active", None)
            current_context = getattr(active_space, "context", None)
            if current_context:
                current_context = str(current_context)
                entry["context"] = current_context
                properties_contexts.append(current_context)
        areas.append(entry)
    return areas, sorted(set(properties_contexts))


def observe_state(bpy_module: Any) -> dict[str, Any]:
    """Return a bounded, JSON-safe snapshot without mutating Blender state."""

    context = bpy_module.context
    scene = context.scene
    objects = list(getattr(scene, "objects", ()))
    active_object = getattr(context, "active_object", None)
    if active_object is None:
        view_layer = getattr(context, "view_layer", None)
        active_object = getattr(getattr(view_layer, "objects", None), "active", None)

    areas, properties_contexts = _screen_areas(context)
    app = getattr(bpy_module, "app", None)
    version = tuple(getattr(app, "version", (0, 0, 0)))
    version_string = str(getattr(app, "version_string", ".".join(str(part) for part in version)))

    return {
        "bridge_protocol_version": 1,
        "blender": {
            "version": list(version),
            "version_string": version_string,
        },
        "scene": {
            "name": str(getattr(scene, "name", "")),
            "object_count": len(objects),
            "objects_truncated": len(objects) > MAX_OBJECTS,
        },
        "mode": str(getattr(context, "mode", "UNKNOWN")),
        "active_object": _object_summary(active_object, detailed=True) if active_object is not None else None,
        "objects": [_object_summary(obj, detailed=False) for obj in objects[:MAX_OBJECTS]],
        "areas": areas,
        "properties_contexts": properties_contexts,
    }
