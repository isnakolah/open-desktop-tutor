PYTHON ?= python3
PACKCTL := PYTHONPATH=tools/packctl/src $(PYTHON) -m open_tutor_pack
BLENDER_ADDON := build/blender/open-desktop-tutor-blender-0.1.0.zip

.PHONY: test pack-check pack-build pack-search blender-addon blender-test openclaw-test tools-test setup-macos

test: pack-check blender-test openclaw-test tools-test
	PYTHONPATH=tools/packctl/src $(PYTHON) -m unittest discover -s tools/packctl/tests -v

pack-check:
	$(PACKCTL) validate packs/blender

pack-build:
	mkdir -p build/packs
	$(PACKCTL) compile packs/blender --output build/packs/blender.otpack

pack-search: pack-build
	$(PACKCTL) search build/packs/blender.otpack "$(QUERY)"

blender-addon:
	$(PYTHON) tools/package_blender_addon.py --output $(BLENDER_ADDON)

blender-test:
	$(PYTHON) -m unittest discover -s bridges/blender/tests -v

openclaw-test:
	cd integrations/openclaw && npm test

tools-test:
	$(PYTHON) -m unittest discover -s tools/tests -v

setup-macos:
	./scripts/setup-macos.sh
