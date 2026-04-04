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

test: ## Run unit tests on iPad simulator with coverage
	xcodebuild test \
		-workspace iPadDx.xcworkspace \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
		-enableCodeCoverage YES \
		-resultBundlePath build/TestResults.xcresult \
		2>&1 | xcbeautify || true
	@echo ""
	@echo "=== Coverage Report ==="
	@xcrun xccov view --report --only-targets build/TestResults.xcresult 2>/dev/null || \
		echo "(Install xcbeautify: brew install xcbeautify)"
	@echo ""
	@echo "Test results saved to build/TestResults.xcresult"
	@echo "Open in Xcode: open build/TestResults.xcresult"

test-ci: ## Run tests without xcbeautify (for CI)
	xcodebuild test \
		-workspace iPadDx.xcworkspace \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
		-enableCodeCoverage YES \
		-resultBundlePath build/TestResults.xcresult \
		2>&1 | tail -30
	xcrun xccov view --report --only-targets build/TestResults.xcresult

coverage: ## View coverage report from last test run
	@xcrun xccov view --report --only-targets build/TestResults.xcresult 2>/dev/null || \
		echo "No test results found. Run 'make test' first."

check: typecheck lint format-check ## Run all checks (typecheck + lint + format)

fix: lint-fix format ## Auto-fix lint issues and format code

open: ## Open project in Xcode
	open $(PROJECT)

frameworks: ## Build embedded bridge frameworks from source
	@echo "Building Flutter bridge..."
	@cd Bridges/flutter_bridge && flutter build ios-framework --no-debug --no-profile \
		--output=../../build/flutter_frameworks 2>&1 | tail -5
	@mkdir -p Frameworks
	@rm -rf Frameworks/Flutter.xcframework Frameworks/App.xcframework
	@cp -R build/flutter_frameworks/Release/Flutter.xcframework Frameworks/
	@cp -R build/flutter_frameworks/Release/App.xcframework Frameworks/
	@echo "✓ Flutter frameworks built and copied to Frameworks/"

pods: ## Install CocoaPods dependencies (Capacitor + Cordova)
	@cd Bridges/capacitor_bridge && npm install 2>&1 | tail -3
	@pod install 2>&1 | tail -3
	@echo "✓ Pods installed — use iPadDx.xcworkspace from now on"

cordova-js: ## Copy real cordova.js into bundled resources
	@mkdir -p Bridges/cordova_bridge/www iPadDx/Resources/cordova_www
	@cp Bridges/capacitor_bridge/node_modules/@capacitor/core/cordova.js Bridges/cordova_bridge/www/cordova.js
	@cp Bridges/cordova_bridge/www/cordova.js iPadDx/Resources/cordova_www/cordova.js
	@cp Bridges/cordova_bridge/www/index.html iPadDx/Resources/cordova_www/index.html
	@echo "✓ cordova.js copied to cordova_www bundle"

bridges: frameworks pods cordova-js ## Build all bridge dependencies

setup: ## Install development dependencies
	brew install swiftlint swiftformat cocoapods
	brew install --cask flutter
	@echo "Then run: make bridges"
