.PHONY: build clean lint format check test open help

# Configuration
PROJECT = iPadDx.xcodeproj
TARGET = iPadDx
SDK = iphoneos
SCHEME = iPadDx
SWIFT_FILES = $(shell find iPadDx -name "*.swift" -not -path "*/.*")

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build for device (no code signing)
	xcodebuild -project $(PROJECT) -target $(TARGET) -sdk $(SDK) build \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
		2>&1 | tail -5

build-sim: ## Build for iPad simulator
	xcodebuild -project $(PROJECT) -target $(TARGET) -sdk iphonesimulator build \
		2>&1 | tail -5

clean: ## Clean build artifacts
	xcodebuild -project $(PROJECT) -target $(TARGET) clean 2>&1 | tail -3
	rm -rf build/ DerivedData/

typecheck: ## Type-check all Swift files
	@SDK_PATH=$$(xcrun --sdk iphoneos --show-sdk-path) && \
	swiftc -typecheck -sdk "$$SDK_PATH" -target arm64-apple-ios17.0 $(SWIFT_FILES) && \
	echo "✓ Type check passed" || echo "✗ Type check failed"

lint: ## Run SwiftLint
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --config .swiftlint.yml iPadDx/; \
	else \
		echo "SwiftLint not installed. Run: brew install swiftlint"; \
	fi

lint-fix: ## Run SwiftLint with auto-fix
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --fix --config .swiftlint.yml iPadDx/; \
	else \
		echo "SwiftLint not installed. Run: brew install swiftlint"; \
	fi

format: ## Format Swift files with SwiftFormat
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat iPadDx/ --config .swiftformat; \
		echo "✓ Formatting complete"; \
	else \
		echo "SwiftFormat not installed. Run: brew install swiftformat"; \
	fi

format-check: ## Check formatting without modifying files
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat iPadDx/ --config .swiftformat --lint && \
		echo "✓ Formatting OK" || echo "✗ Formatting issues found"; \
	else \
		echo "SwiftFormat not installed. Run: brew install swiftformat"; \
	fi

check: typecheck lint format-check ## Run all checks (typecheck + lint + format)

fix: lint-fix format ## Auto-fix lint issues and format code

open: ## Open project in Xcode
	open $(PROJECT)

setup: ## Install development dependencies
	brew install swiftlint swiftformat
