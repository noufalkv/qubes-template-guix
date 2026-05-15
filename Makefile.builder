# SPDX-License-Identifier: GPL-3.0-or-later
ifeq ($(DIST),guix)
    GUIX_PLUGIN_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
    DISTRIBUTION := guix
    BUILDER_MAKEFILE = $(GUIX_PLUGIN_DIR)Makefile
    TEMPLATE_SCRIPTS = $(GUIX_PLUGIN_DIR)
endif

# vim: ft=make
