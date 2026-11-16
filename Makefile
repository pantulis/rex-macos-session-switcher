# Where Rex keeps its configuration: REX_CONFIG's directory, else XDG_CONFIG_HOME/rex,
# else ~/.config/rex.
CONFIG_DIR ?= $(if $(REX_CONFIG),$(patsubst %/,%,$(dir $(REX_CONFIG))),$(if $(XDG_CONFIG_HOME),$(XDG_CONFIG_HOME)/rex,$(HOME)/.config/rex))
PREFIX ?= $(CONFIG_DIR)/rex-macos-session-switcher
INIT_LUA ?= $(if $(REX_CONFIG),$(REX_CONFIG),$(CONFIG_DIR)/init.lua)
LOAD_LINE = dofile("$(PREFIX)/session-switcher.lua")

.PHONY: build install enable uninstall clean

build: rex-session-switcher

rex-session-switcher: switcher.swift
	@command -v swiftc >/dev/null || { \
	  echo "swiftc not found. Install the Command Line Tools: xcode-select --install" >&2; exit 1; }
	swiftc -O -o $@ switcher.swift

# Builds the helper and copies it, with the Lua file, into Rex's config directory.
install: build
	mkdir -p "$(PREFIX)"
	cp rex-session-switcher session-switcher.lua "$(PREFIX)/"
	@echo "Installed to $(PREFIX)"
	@echo "Run 'make enable' to load it from init.lua, or add this line yourself:"
	@echo '  $(LOAD_LINE)'

# Adds the load line to init.lua (once) and reloads Rex's configuration.
enable:
	mkdir -p "$(dir $(INIT_LUA))"
	touch "$(INIT_LUA)"
	@grep -qF 'session-switcher.lua' "$(INIT_LUA)" || echo '$(LOAD_LINE)' >> "$(INIT_LUA)"
	-rex config reload
	@echo "If Rex.app is open, also run: rex -C <client> do client.config.reload"

# Removes the installed files. Delete the load line from init.lua yourself.
uninstall:
	rm -rf "$(PREFIX)"

clean:
	rm -f rex-session-switcher
