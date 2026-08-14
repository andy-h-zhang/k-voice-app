# KVoice — repo-root developer commands.
#
# `Core` is a standalone Swift package (KVoiceCore library + speakerlab CLI)
# and can be built/tested on its own. `App` + `project.yml` are consumed by
# XcodeGen to produce KVoice.xcodeproj, which is generated on demand and
# never hand-edited or committed (see .gitignore).

.PHONY: build test generate app-build release clean

CORE_DIR := Core
XCODEPROJ := KVoice.xcodeproj
SCHEME := KVoice

# Build the Core Swift package (KVoiceCore library + speakerlab CLI).
build:
	cd $(CORE_DIR) && swift build

# Run the Core package's test suite.
#
# Command Line Tools-only installs (no full Xcode.app) stage Testing.framework
# under Xcode-style paths ($DEVELOPER_DIR/Library/Developer/Frameworks) that
# bare `swift test` doesn't search, so it fails with "no such module 'Testing'"
# (or a dlopen failure once the module is found). We detect that case at
# runtime and add the matching -F search path plus the two runtime -rpaths
# Testing.framework and its lib_TestingInterop.dylib dependency need. Full-Xcode
# machines have a Platforms/ dir and need no extra flags.
#
# This machine now has full Xcode, so the workaround is dormant here — the else
# branch runs. It is kept because `make build` and `make test` are still
# documented as working on a Command Line Tools-only checkout (the app targets,
# `app-build` and `release`, do require full Xcode).
test:
	@dev="$$(xcode-select -p)"; \
	if [ -d "$$dev/Library/Developer/Frameworks/Testing.framework" ] && [ ! -d "$$dev/Platforms" ]; then \
		echo "note: CLT-only toolchain at $$dev — applying Swift Testing rpath workaround (see Makefile comment)"; \
		cd $(CORE_DIR) && swift test \
			-Xswiftc -F -Xswiftc "$$dev/Library/Developer/Frameworks" \
			-Xlinker -rpath -Xlinker "$$dev/Library/Developer/Frameworks" \
			-Xlinker -rpath -Xlinker "$$dev/Library/Developer/usr/lib"; \
	else \
		cd $(CORE_DIR) && swift test; \
	fi

# Regenerate KVoice.xcodeproj from project.yml via XcodeGen.
generate:
	@command -v xcodegen >/dev/null 2>&1 || { \
		echo "error: xcodegen is not installed."; \
		echo "Install it with 'brew install xcodegen' (https://github.com/yonaskolb/XcodeGen), then re-run 'make generate'."; \
		exit 1; \
	}
	xcodegen generate --spec project.yml

# Build the generated macOS app via xcodebuild (regenerates the project first).
app-build: generate
	@command -v xcodebuild >/dev/null 2>&1 || { \
		echo "error: xcodebuild is not available."; \
		echo "Install full Xcode (not just the Command Line Tools), then run"; \
		echo "'sudo xcode-select -s /Applications/Xcode.app' and accept its license."; \
		exit 1; \
	}
	@[ -d "$(XCODEPROJ)" ] || { \
		echo "error: $(XCODEPROJ) not found even after 'make generate' — check project.yml."; \
		exit 1; \
	}
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -destination 'platform=macOS' build

# Build a signed, Release-configuration KVoice.app into build/release/.
#
# `test` runs first, deliberately: a release never ships untested. `generate`
# then guarantees the project matches project.yml. Identity detection (Developer
# ID if the keychain has one, ad-hoc otherwise), the codesign pass, and the
# final .app path report all live in Scripts/release.sh — see the README's
# "Release builds" section for how to switch identities.
release: test generate
	@./Scripts/release.sh

# Remove build artifacts (SwiftPM .build, the generated Xcode project, and the
# release output tree).
clean:
	cd $(CORE_DIR) && swift package clean
	rm -rf $(XCODEPROJ) build
