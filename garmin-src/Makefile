-include local.mk

SDK_DIR   := $(shell cat $(HOME)/.Garmin/ConnectIQ/current-sdk.cfg)
MONKEYC   := $(SDK_DIR)bin/monkeyc
MONKEYDO  := $(SDK_DIR)bin/monkeydo
SIMULATOR := $(SDK_DIR)bin/connectiq

KEY       := $(HOME)/.Garmin/developer_key.der
DEVICE    := fenix7xpro
OUT       := bin/spk412.prg

.PHONY: config build release sim run clean

config:
	@if [ -z "$(GITHUB_USER)" ]; then \
		echo "Blad: ustaw GITHUB_USER w local.mk lub odpal: make run GITHUB_USER=twoj_nick"; \
		exit 1; \
	fi
	@printf '(:glance)\nmodule Config {\n    const BASE_URL = "https://%s.github.io/Garmin-Kursy-SPK";\n}\n' "$(GITHUB_USER)" > source/Config.mc

build: config
	$(MONKEYC) -d $(DEVICE) -f monkey.jungle -o $(OUT) -y $(KEY) -w -l 1

release: config
	$(MONKEYC) -d $(DEVICE) -f monkey.jungle -o $(OUT) -y $(KEY) -r -w -l 1

sim:
	$(SIMULATOR) &

run: build
	$(MONKEYDO) $(OUT) $(DEVICE)

clean:
	rm -rf bin/*.prg bin/*.prg.debug.xml source/Config.mc
