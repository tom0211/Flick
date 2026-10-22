APP := build/Flick.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build app run install icon list clean

build:
	swift build

app:
	scripts/bundle.sh

# Opening an app while its previous instance is still exiting fails with LaunchServices error -600, hence the wait.
run: app
	-pkill -x Flick && sleep 1
	open $(APP)

# Moves rather than copies, and makes the system forget the build copy, so Spotlight and "Open With" only
# ever list the installed app.
install: app
	-pkill -x Flick && sleep 1
	rm -rf /Applications/Flick.app
	-$(LSREGISTER) -u $(APP)
	mv $(APP) /Applications/Flick.app
	open /Applications/Flick.app

icon:
	scripts/make-icon.sh

list: build
	$$(swift build --show-bin-path)/Flick --list

clean:
	rm -rf .build build
