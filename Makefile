# Developer entry points. Everything, including releases, runs from the host —
# no hosted CI.

XCODEPROJ := Fader.xcodeproj
SCHEME    := Fader

# wrangler auth: the infra repo's Cloudflare token is the single source of
# truth; its OAuth session points at the wrong account.
export CLOUDFLARE_ACCOUNT_ID := 256a25a6ed7e920b09a562595db72539
export CLOUDFLARE_API_TOKEN := $(shell grep ^CLOUDFLARE_API_TOKEN= $(HOME)/projects/pantafive/infra/.env | cut -d= -f2)
IDENTITY  := Developer ID Application: Mikhail Solomenik (7T47AFG34U)
NOTARY    := Stenografista-Notarize
APP       := build/Build/Products/Release/Fader.app
DMG       := dist/Fader-$(APP_VERSION).dmg

.PHONY: gen build test lint format run clean check-version release publish site

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug \
		CODE_SIGNING_ALLOWED=NO build

test: gen
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug \
		CODE_SIGNING_ALLOWED=NO test

lint:
	swiftformat --lint .
	swiftlint --strict

format:
	swiftformat .

run: build
	open "$$(xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Debug \
		-showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $$3}')/Fader.app"

clean:
	rm -rf build dist $(XCODEPROJ)

check-version:
ifndef APP_VERSION
	$(error APP_VERSION is required, e.g. APP_VERSION=0.1.0 make release)
endif

# Build → sign → notarize the app → dmg → notarize the dmg. Run tests first.
release: check-version test
	xcodegen generate
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Release \
		MARKETING_VERSION=$(APP_VERSION) \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$(IDENTITY)" \
		DEVELOPMENT_TEAM=7T47AFG34U \
		OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
		-derivedDataPath build build
	mkdir -p dist
	ditto -c -k --keepParent "$(APP)" dist/Fader.zip
	xcrun notarytool submit dist/Fader.zip --keychain-profile "$(NOTARY)" --wait
	xcrun stapler staple "$(APP)"
	rm -rf dist/dmg dist/Fader.zip
	mkdir -p dist/dmg
	cp -R "$(APP)" dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname "Fader" -srcfolder dist/dmg -ov -format UDZO "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY)" --wait
	xcrun stapler staple "$(DMG)"
	rm -rf dist/dmg
	@echo "Ready: $(DMG)"

# Upload the dmg to R2 (versioned + latest), tag, and create a GitHub release.
publish: check-version
	wrangler r2 object put "fader/Fader-v$(APP_VERSION).dmg" \
		--file "$(DMG)" --content-type application/x-apple-diskimage
	wrangler r2 object put "fader/Fader.dmg" \
		--file "$(DMG)" --content-type application/x-apple-diskimage
	git tag "v$(APP_VERSION)"
	git push origin "v$(APP_VERSION)"
	GH_TOKEN=$$(gh auth token -u pantafive) gh release create "v$(APP_VERSION)" "$(DMG)" \
		--repo pantafive/fader --title "Fader $(APP_VERSION)" --generate-notes

# Deploy the landing page to Cloudflare Pages (fader.pantafive.dev).
site:
	wrangler pages deploy site --project-name=fader --branch=main --commit-dirty=true
