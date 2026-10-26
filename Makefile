SWIFTC ?= swiftc
UNAME := $(shell uname)
ifeq ($(UNAME),Darwin)
SDK_FLAG := -sdk $(shell xcrun --sdk macosx --show-sdk-path)
else
SDK_FLAG :=
endif

.PHONY: test dmg

test:
	mkdir -p build
	$(SWIFTC) -swift-version 5 $(SDK_FLAG) -Onone -g -o build/utilbox-tests Sources/ClipDropCore/*.swift Tests/RunTests.swift
	./build/utilbox-tests

dmg:
	./build.sh
