"""Blender add-on entrypoint for the read-only Open Desktop Tutor bridge."""

bl_info = {
    "name": "Open Desktop Tutor Bridge",
    "author": "Open Desktop Tutor contributors",
    "version": (0, 2, 0),
    "blender": (5, 2, 0),
    "location": "Preferences > Add-ons",
    "description": "Expose bounded read-only Blender state to the local Open Desktop Tutor host",
    "category": "Interface",
}

_runtime = None


def register():
    global _runtime
    import bpy

    from open_desktop_tutor_blender.server import BlenderBridgeRuntime

    if _runtime is None:
        _runtime = BlenderBridgeRuntime(bpy)
        descriptor = _runtime.start()
        print(f"Open Desktop Tutor bridge started; descriptor: {descriptor}")


def unregister():
    global _runtime
    if _runtime is not None:
        _runtime.stop()
        _runtime = None
        print("Open Desktop Tutor bridge stopped")
