.PHONY: build test release-check release publish help

build:
	Scripts/build.sh

test:
	swift test --disable-automatic-resolution
	python3 -m unittest discover -s Tests/BuildChecks -v

release-check:
	@test -n "$(VERSION)" || (echo 'Usage: make release-check VERSION=X.Y.Z'; exit 1)
	python3 Scripts/release.py check "$(VERSION)"

release:
	@test -n "$(VERSION)" || (echo 'Usage: make release VERSION=X.Y.Z [BUILD_NUMBER=N]'; exit 1)
	python3 Scripts/release.py prepare "$(VERSION)" $(if $(filter true,$(CRITICAL)),--critical,)

publish:
	@test -n "$(VERSION)" || (echo 'Usage: make publish VERSION=X.Y.Z [BUILD_NUMBER=N]'; exit 1)
	python3 Scripts/release.py publish "$(VERSION)"

help:
	@echo 'make build / make test'
	@echo 'make release VERSION=X.Y.Z [BUILD_NUMBER=N] [CRITICAL=true]'
	@echo 'make publish VERSION=X.Y.Z [BUILD_NUMBER=N]'
