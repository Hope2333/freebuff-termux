#!/data/data/com.termux/files/usr/bin/make
# Freebuff for Termux — build system
SHELL := /data/data/com.termux/files/usr/bin/bash
.DEFAULT_GOAL := help

PROJECT_DIR := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))
TOOLS_DIR   := $(PROJECT_DIR)/tools
SCRIPTS_DIR := $(PROJECT_DIR)/scripts
ARTIFACTS   := $(PROJECT_DIR)/artifacts
STAGED      := $(ARTIFACTS)/staged

HOOK_SRC    := $(TOOLS_DIR)/hook.c
HOOK_OUT    := $(TOOLS_DIR)/hook.so
WRAPPER_SRC := $(SCRIPTS_DIR)/freebuff-wrapper.c
WRAPPER_OUT := $(SCRIPTS_DIR)/freebuff-wrapper

BINARY_DIR  := $(HOME)/.config/manicode
BINARY_PATH := $(BINARY_DIR)/freebuff

GLIBC_INC   := /data/data/com.termux/files/usr/glibc/include
GLIBC_LIB   := /data/data/com.termux/files/usr/glibc/lib

# Release upload target variables
TAG ?= Push$(shell date +%y%m%d)
REPO ?= Hope2333/freebuff-termux
VER ?= latest
VERS ?=
PKG ?= both
PACKAGER_NAME ?= Hope2333(幽零小喵) <u0catmiao@proton.me>
ODIR ?=
MIX ?= 0
OUTPUT_ROOT := $(if $(ODIR),$(ODIR),$(PROJECT_DIR)/packing)

# ═══════════════════════════════════════════════════════════════════
.PHONY: help all deb pacman batch release-upload version deps produce stage install test clean dev

help:
	@echo "Freebuff for Termux — build system"
	@echo ""
	@echo "Primary commands:"
	@echo "  make all VER=0.0.106 PKG=both"
	@echo "  make all VER=latest PKG=deb"
	@echo "  make dev                        produce + stage + test"
	@echo "  make install                    install to system"
	@echo ""
	@echo "Package targets:"
	@echo "  make deb VERSION=0.0.106"
	@echo "  make pacman VERSION=0.0.106"
	@echo "  make batch VERS='0.0.106 0.0.105' PKG=both ODIR=~/fb-out"
	@echo "  make release-upload VERS='0.0.106'"
	@echo ""

all: produce stage
	@V="$(VER)"; \
	if [ "$$V" = "latest" ]; then V=""; fi; \
	if [ "$(PKG)" = "deb" ]; then \
		$(MAKE) deb VERSION=$$V; \
	elif [ "$(PKG)" = "pacman" ]; then \
		$(MAKE) pacman VERSION=$$V; \
	else \
		$(MAKE) deb VERSION=$$V && $(MAKE) pacman VERSION=$$V; \
	fi

batch:
	@if [ -z "$(VERS)" ]; then \
		echo "Error: VERS is empty. Example: make batch VERS='0.0.105 0.0.106' PKG=both"; \
		exit 1; \
	fi; \
	for v in $(VERS); do \
		echo "=== Batch build for version $$v ==="; \
		$(MAKE) all VER=$$v PKG=$(PKG) PACKAGER_NAME='$(PACKAGER_NAME)' ODIR='$(ODIR)' MIX='$(MIX)' || exit 1; \
	done

# ═══════════════════════════════════════════════════════════════════
version:
	@echo "Freebuff Termux"
	@echo "  Project: $(PROJECT_DIR)"
	@echo "  Binary:  $(BINARY_PATH)"
	@-test -f "$(BINARY_PATH)" && echo "  Version: $$(timeout 5 $(BINARY_PATH) --version 2>/dev/null || echo '(unknown)')" || true
	@-test -f "$(BINARY_PATH)" && echo "  Size:    $$(du -h "$(BINARY_PATH)" | cut -f1)" || true

deps:
	@echo "Checking dependencies..."
	@for cmd in gcc npm patchelf; do \
		if command -v $$cmd >/dev/null 2>&1; then \
			echo "  [✓] $$cmd"; \
		else \
			echo "  [✗] $$cmd — install: pkg install $$cmd"; \
		fi; \
	done

# ═══════════════════════════════════════════════════════════════════
produce:
	@echo "=== Produce ==="
	@bash "$(TOOLS_DIR)/produce-local.sh"

stage: produce
	@echo "=== Stage ==="
	@bash "$(SCRIPTS_DIR)/build.sh"

deb:
	rm -rf packing/dpkg/work
	MAINTAINER='$(PACKAGER_NAME)' ./scripts/package/package_deb.sh
	@if [ "$(MIX)" = "1" ]; then \
		mkdir -p "$(OUTPUT_ROOT)" && cp -f packing/dpkg/freebuff_*.deb "$(OUTPUT_ROOT)/" 2>/dev/null || true; \
	else \
		mkdir -p "$(OUTPUT_ROOT)/deb" && cp -f packing/dpkg/freebuff_*.deb "$(OUTPUT_ROOT)/deb/" 2>/dev/null || true; \
	fi

pacman:
	rm -rf packing/pacman/pkg packing/pacman/src
	PACKAGER_NAME='$(PACKAGER_NAME)' ./scripts/package/package_pacman.sh
	@if [ "$(MIX)" = "1" ]; then \
		mkdir -p "$(OUTPUT_ROOT)" && cp -f packing/pacman/freebuff-*.pkg.* "$(OUTPUT_ROOT)/" 2>/dev/null || true; \
	else \
		mkdir -p "$(OUTPUT_ROOT)/pacman" && cp -f packing/pacman/freebuff-*.pkg.* "$(OUTPUT_ROOT)/pacman/" 2>/dev/null || true; \
	fi

# ═══════════════════════════════════════════════════════════════════
install: stage
	@echo "=== Install ==="
	install -m 755 "$(STAGED)/bin/freebuff" "/data/data/com.termux/files/usr/bin/freebuff"
	@mkdir -p "/data/data/com.termux/files/usr/lib/freebuff/runtime"
	install -m 755 "$(STAGED)/lib/freebuff/runtime/freebuff" "/data/data/com.termux/files/usr/lib/freebuff/runtime/freebuff"
	install -m 644 "$(STAGED)/lib/freebuff/hook.so" "/data/data/com.termux/files/usr/lib/freebuff/hook.so" 2>/dev/null || true
	@echo ""
	@echo "[✓] Installed! Run: freebuff"

test:
	@echo "=== Test ==="
	@bash "$(SCRIPTS_DIR)/test.sh"

clean:
	@echo "Cleaning..."
	@rm -rf "$(STAGED)" packing/dpkg/work packing/pacman/pkg packing/pacman/src
	@rm -f "$(WRAPPER_OUT)" "$(HOOK_OUT)"
	@echo "  Removed build artifacts"
	@echo "[✓] Clean"

dev: produce stage test
	@echo ""
	@echo "[✓] dev complete"

# ═══════════════════════════════════════════════════════════════════
release-upload:
	@if [ -z "$(VERS)" ]; then \
		echo "Error: VERS is required. Example: make release-upload VERS='0.0.106' TAG=Push260611"; \
		exit 1; \
	fi
	@echo "=== Release upload: TAG=$(TAG) VERS=$(VERS) PKG=$(PKG) REPO=$(REPO) ==="
	$(MAKE) batch VERS='$(VERS)' PKG='$(PKG)' ODIR='/tmp/fb-release-$(TAG)' MIX=1
	@echo "=== Uploading to release $(TAG) ==="; \
	if ! gh release view "$(TAG)" --repo "$(REPO)" >/dev/null 2>&1; then \
		echo "Creating release $(TAG)..."; \
		gh release create "$(TAG)" --repo "$(REPO)" --title "$(TAG)" --notes "Automated build $$(date -u +%Y-%m-%d)" 2>&1 || exit 1; \
	fi; \
	for f in /tmp/fb-release-$(TAG)/freebuff_*.deb /tmp/fb-release-$(TAG)/freebuff-*.pkg.*; do \
		if [ -f "$$f" ]; then \
			echo "  uploading $$(basename $$f)..."; \
			gh release upload "$(TAG)" "$$f" --repo "$(REPO)" --clobber 2>&1 || true; \
		fi; \
	done; \
	echo "=== Done: https://github.com/$(REPO)/releases/tag/$(TAG) ==="
