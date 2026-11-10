.PHONY: build app run release clean
build:
	swift build --arch arm64
app:
	scripts/make-app.sh debug
release:
	scripts/make-app.sh release
run: app
	open "dist/MP4 nxnative.app"
clean:
	rm -rf .build dist
