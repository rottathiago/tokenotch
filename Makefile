.PHONY: build universal metadata test test-ci smoke smoke-telemetry vscode-companion smoke-history smoke-timeline smoke-notch gen test-xcode run clean package release docs-check docs-links-external

docs-check:
	node scripts/docs/check.mjs
	npm test --prefix scripts/docs

docs-links-external:
	node scripts/docs/check.mjs --external

build:
	bash scripts/build.sh

universal:
	bash scripts/build.sh --universal

metadata:
	python3 scripts/release-config.py
	python3 scripts/make-brand-assets.py --check
	python3 scripts/check-project.py

test test-ci:
	@xcodebuild -version >/dev/null 2>&1 || { echo "Full Xcode is required for XCTest. Select it with DEVELOPER_DIR; use make smoke for the separate Command Line Tools checks." >&2; exit 1; }
	xcrun swift test
	python3 scripts/test-release.py
	python3 scripts/test-package.py
	python3 scripts/test-project.py

smoke:
	mkdir -p build
	swiftc -swift-version 5 -parse-as-library sources/Core/*.swift \
		sources/Notch/{NotchGeometry,NotchEdge,SideNotchShape,NotchLayout,FullScreenDetector}.swift \
		sources/DesignSystem/Design.swift sources/Settings/DisplayPreference.swift \
		sources/L10n.swift tests/HistoryChecks.swift tests/UsageTimelineChecks.swift tests/ActivityChecks.swift tests/CacheInputChecks.swift tests/ContextChecks.swift tests/ProductionChecks.swift scripts/smoke.swift -lsqlite3 -o build/tokenotch-smoke
	build/tokenotch-smoke
	node --experimental-vm-modules scripts/extension-smoke.mjs
	node --experimental-vm-modules scripts/context-extension-smoke.mjs

smoke-telemetry:
	mkdir -p build
	swiftc -swift-version 5 -parse-as-library sources/Core/*.swift \
		tests/TelemetryChecks.swift tests/SourceHistoryChecks.swift tests/TelemetryImportChecks.swift \
		scripts/telemetry-smoke.swift -lsqlite3 -o build/tokenotch-telemetry-smoke
	build/tokenotch-telemetry-smoke

vscode-companion:
	python3 scripts/release-config.py
	cd integrations/VSCode && npm ci --ignore-scripts --no-audit --no-fund && npm test && npm run package

smoke-history: build
	swiftc -swift-version 5 -D HISTORY_SMOKE -parse-as-library \
		-I build/native -L build/native -lTokenotchCore -lsqlite3 \
		sources/App/HistoryController.swift tests/HistoryChecks.swift tests/TelemetryChecks.swift tests/HistoryLifecycleChecks.swift \
		scripts/history-smoke.swift -o build/tokenotch-history-smoke
	build/tokenotch-history-smoke

smoke-timeline: build
	swiftc -swift-version 5 -D HISTORY_SMOKE -parse-as-library \
		-I build/native -L build/native -lTokenotchCore -lsqlite3 \
		sources/App/HistoryController.swift sources/App/SessionTimelineController.swift \
		tests/HistoryChecks.swift tests/TelemetryChecks.swift tests/HistoryLifecycleChecks.swift tests/HistoryInsightChecks.swift \
		tests/TimelineChecks.swift tests/TimelineLifecycleChecks.swift scripts/timeline-smoke.swift \
		-o build/tokenotch-timeline-smoke
	build/tokenotch-timeline-smoke

smoke-notch: build
	swiftc -swift-version 5 -D NOTCH_SMOKE -parse-as-library \
		-I build/native -L build/native -lTokenotchCore -lsqlite3 \
		sources/App/TokenotchModel.swift sources/App/OnboardingState.swift sources/App/ReleaseUpdateController.swift sources/App/VSCodeIntegrationController.swift sources/App/HistoryController.swift sources/App/SessionTimelineController.swift sources/App/SessionAttentionController.swift sources/Notch/*.swift sources/DesignSystem/*.swift \
		sources/Settings/*.swift sources/L10n.swift \
		tests/NotchTestSupport.swift tests/ContextNotchChecks.swift tests/NotificationDeliveryChecks.swift tests/UsageTimelineNotchChecks.swift tests/UsageReportingChecks.swift tests/SessionAttentionChecks.swift tests/ConnectionsChecks.swift \
		tests/TelemetryChecks.swift tests/VSCodeIntegrationChecks.swift tests/ProductionAppChecks.swift tests/OnboardingChecks.swift scripts/notch-smoke.swift -o build/tokenotch-notch-smoke
	cp sources/Resources/Brand/*.png build/
	build/tokenotch-notch-smoke $(NOTCH_SMOKE_ARGS)

gen: metadata vscode-companion
	xcodegen generate

test-xcode: gen
	xcodebuild -quiet -project Tokenotch.xcodeproj -scheme Tokenotch -destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO test

run: build
	open build/Tokenotch.app

clean:
	swift package clean

package:
	python3 scripts/package.py $(PACKAGE_ARGS)

release:
	python3 scripts/release.py
