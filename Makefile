CC ?= gcc
CFLAGS ?= -std=c99 -Wall -Wextra -Werror -pedantic -Isrc
BUILD_DIR := build
RELEASE_DIR := release
# Relative path from inside $(BUILD_DIR) back to the repo root; recipes
# cd into $(BUILD_DIR), which may be nested (e.g. build/nex).
empty :=
space := $(empty) $(empty)
BUILD_DIR_UP := $(subst $(space),,$(patsubst %,../,$(subst /, ,$(BUILD_DIR))))
ZCC ?= zcc
Z80ASM ?= z80asm
SJASMPLUS ?= sjasmplus
POWERSHELL ?= pwsh
PYTHON ?= python3
CMAKE ?= cmake
CTEST ?= ctest
MACDEPLOYQT ?= macdeployqt
CODESIGN ?= codesign
DITTO ?= ditto
QTPATHS ?= qtpaths6
ZX_EXTRA_CFLAGS ?=
CLIENT_BUILD ?= auto
CLIENT_CMAKE_BUILD_DIR ?= $(BUILD_DIR)/qt-client
CLIENT_CMAKE_CONFIG ?= Release
CLIENT_CMAKE_ARGS ?=
CLIENT_MSVC_QT_DIR ?= C:\Qt\6.11.0\msvc2022_64
CLIENT_MSVC_GENERATOR ?= Visual Studio 17 2022
CLIENT_MSVC_ARCH ?= x64
CLIENT_MSVC_CONFIG ?= Release
CLIENT_MSVC_DEPLOY_TIMEOUT ?= 120
CLIENT_MSVC_CLEAN_TIMEOUT ?= 30
CLIENT_MAC_APPLICATIONS_DIR ?= /Applications
HOST_UNAME := $(shell uname -s 2>/dev/null || echo unknown)
CLIENT_HOST_IS_WINDOWS := $(if $(filter Windows_NT,$(OS)),1,$(if $(COMSPEC),1,$(if $(ComSpec),1,$(if $(filter MINGW% MSYS% CYGWIN%,$(HOST_UNAME)),1,))))
HOST_GC_CFLAGS := -ffunction-sections -fdata-sections
HOST_GC_LDFLAGS := -Wl,--gc-sections
ifeq ($(HOST_UNAME),Darwin)
HOST_GC_LDFLAGS := -Wl,-dead_strip
endif

PORT ?= 5000
MQTT_HOST ?= broker.hivemq.com
MQTT_PORT ?= 1883
MQTT_CODE ?= DEVROOM
ZX_NAME := SHATRANJ
APP_VERSION := $(strip $(shell cat VERSION))
ZX_ORG := 28672
ASSET_ASM := assets/spectrum/ui_runtime_assets.asm
ABOUT_BOARD := assets/spectrum/about_board.bin
SPECTRUM_SRC := src/spectrum/app/app.c \
                src/spectrum/app/net_runtime.c \
                src/spectrum/config/session.c \
                src/common/chess/move_coords.c \
                src/common/protocol/game_protocol.c \
                src/common/protocol/game_protocol_extra.c \
                src/common/protocol/direct_session_protocol.c \
                src/common/protocol/mqtt_session_protocol.c \
                src/spectrum/session/direct.c \
                src/spectrum/session/event.c \
                src/spectrum/session/mqtt.c \
                src/spectrum/session/outgoing.c \
                src/spectrum/session/ping.c \
                src/spectrum/session/poll.c \
                src/spectrum/platform/platform.c \
                src/spectrum/transport/esp_at.c \
                src/spectrum/transport/keepalive_protocol.c \
                src/spectrum/transport/net.c \
                src/spectrum/transport/mqtt_session_wire.c \
                src/spectrum/transport/mqtt_min.c \
                src/spectrum/board/board.c \
                src/spectrum/board/san.c \
                src/spectrum/saveload/saveload.c \
                src/spectrum/fileui/fileui.c \
                src/spectrum/restore/restore.c \
                src/spectrum/ui/gui.c \
                src/spectrum/overlay/overlay.c
PIECE_ASM := assets/spectrum/chess_pieces_16x16.asm

RULES_TEST := $(BUILD_DIR)/netchesszx_rules_test.exe
RULES_TEST_SRC := src/common/chess/position.c src/common/chess/legal.c \
                  src/common/chess/rules_compact.c tests/rules/test_fen.c
MOVE_COORDS_TEST := $(BUILD_DIR)/netchesszx_move_coords_test.exe
MOVE_COORDS_TEST_SRC := src/common/chess/move_coords.c tests/common/test_move_coords.c
SAVEGAME_WIRE_TEST := $(BUILD_DIR)/netchesszx_savegame_wire_test.exe
SAVEGAME_WIRE_TEST_SRC := src/common/savegame/savegame_wire.c \
                          src/spectrum/overlay/restore_ovl.c \
                          tests/common/test_savegame_wire.c
BOARD_TEST := $(BUILD_DIR)/netchesszx_spectrum_board_test.exe
BOARD_TEST_SRC := src/common/chess/move_coords.c \
                  src/spectrum/board/board.c src/spectrum/board/san.c \
                  src/common/chess/rules_compact.c \
                  src/common/chess/legal.c tests/spectrum/test_board.c
RULES_COMPACT_PERFT_TEST := $(BUILD_DIR)/netchesszx_rules_compact_perft_test.exe
RULES_COMPACT_PERFT_TEST_SRC := src/common/chess/move_coords.c \
                                src/spectrum/board/board.c \
                                src/common/chess/rules_compact.c \
                                tests/spectrum/test_rules_compact_perft.c
MQTT_TEST := $(BUILD_DIR)/netchesszx_mqtt_test.exe
MQTT_TEST_SRC := src/common/mqtt/mqtt.c src/spectrum/transport/mqtt_min.c \
                 tests/net/test_mqtt.c
MQTT_STREAM_TEST := $(BUILD_DIR)/netchesszx_mqtt_stream_test.exe
MQTT_STREAM_TEST_SRC := tests/spectrum/test_mqtt_stream.c
GAME_PROTOCOL_TEST := $(BUILD_DIR)/netchesszx_game_protocol_test.exe
GAME_PROTOCOL_TEST_SRC := src/common/protocol/game_protocol.c \
                           src/common/protocol/game_protocol_extra.c \
                           src/common/protocol/game_protocol_format.c \
                           tests/net/test_game_protocol.c
ESP_AT_TEST := $(BUILD_DIR)/netchesszx_esp_at_test.exe
ESP_AT_NEXT_TEST := $(BUILD_DIR)/netchesszx_esp_at_next_test.exe
ESP_AT_TEST_SRC := src/spectrum/transport/esp_at.c src/common/protocol/game_protocol.c tests/net/test_esp_at.c
UART_PLATFORM_TEST := $(BUILD_DIR)/netchesszx_uart_platform_test.exe
UART_PLATFORM_TEST_SRC := src/spectrum/platform/platform.c tests/spectrum/test_uart_platform.c
DIRECT_IPD_TEST := $(BUILD_DIR)/netchesszx_direct_ipd_test.exe
DIRECT_IPD_TEST_SRC := tests/spectrum/test_direct_ipd.c \
                       tests/spectrum/text_asm_host.c
MQTT_SESSION_PROTOCOL_TEST := $(BUILD_DIR)/netchesszx_mqtt_session_protocol_test.exe
MQTT_SESSION_PROTOCOL_TEST_SRC := src/common/protocol/mqtt_session_protocol.c \
                                  src/common/protocol/mqtt_session_protocol_format.c \
                                  tests/net/test_mqtt_session_protocol.c
DIRECT_SESSION_PROTOCOL_TEST := $(BUILD_DIR)/netchesszx_direct_session_protocol_test.exe
DIRECT_SESSION_PROTOCOL_TEST_SRC := src/common/protocol/direct_session_protocol.c \
                                    src/common/protocol/game_protocol.c \
                                    tests/net/test_direct_session_protocol.c
SESSION_CORE_TEST := $(BUILD_DIR)/netchesszx_session_core_test.exe
SESSION_CORE_TEST_SRC := src/common/session/session.c \
                         src/common/session/mqtt_session.c \
                         src/common/protocol/game_protocol.c \
                         src/common/protocol/game_protocol_extra.c \
                         src/common/protocol/game_protocol_format.c \
                         src/common/protocol/mqtt_session_protocol.c \
                         src/common/protocol/mqtt_session_protocol_format.c \
                         tests/session/test_session_core.c
SESSION_DIRECT_CORE_TEST := $(BUILD_DIR)/netchesszx_session_direct_core_test.exe
SESSION_DIRECT_CORE_TEST_SRC := src/common/session/session.c \
                                src/common/session/direct_session.c \
                                src/common/session/mqtt_session.c \
                                src/common/protocol/mqtt_session_protocol.c \
                                src/common/protocol/mqtt_session_protocol_format.c \
                                src/common/protocol/direct_session_protocol.c \
                                src/common/protocol/game_protocol.c \
                                src/common/protocol/game_protocol_extra.c \
                                src/common/protocol/game_protocol_format.c \
                                tests/session/test_direct_session_core.c
SESSION_MQTT_PARITY_TEST := $(BUILD_DIR)/netchesszx_mqtt_session_parity_test.exe
SESSION_MQTT_PARITY_TEST_SRC := src/common/session/session.c \
                                   src/common/session/mqtt_session.c \
                                   tests/session/test_mqtt_session_parity.c \
                                  tests/session/mqtt_session_transcripts.c \
                                  tests/spectrum/text_asm_host.c \
                                  src/common/chess/move_coords.c \
                                  src/common/chess/legal.c \
                                  src/common/protocol/direct_session_protocol.c \
                                  src/common/protocol/game_protocol.c \
                                  src/common/protocol/game_protocol_extra.c \
                                  src/common/protocol/game_protocol_format.c \
                                  src/common/protocol/mqtt_session_protocol.c \
                                  src/common/protocol/mqtt_session_protocol_format.c \
                                  src/spectrum/config/session.c \
                                  src/spectrum/session/direct.c \
                                  src/spectrum/session/event.c \
                                  src/spectrum/overlay/control_ovl.c \
                                  src/spectrum/session/mqtt.c \
                                  src/spectrum/session/outgoing.c \
                                  src/spectrum/session/ping.c \
                                  src/spectrum/session/poll.c \
                                  src/spectrum/transport/keepalive_protocol.c \
                                  src/spectrum/transport/mqtt_session_wire.c \
                                  src/spectrum/overlay/restore_ovl.c \
                                  src/spectrum/board/board.c \
                                  src/spectrum/board/san.c \
                                  src/common/chess/rules_compact.c
SESSION_DIRECT_PARITY_TEST := $(BUILD_DIR)/netchesszx_direct_session_parity_test.exe
SESSION_DIRECT_PARITY_NEXT_TEST := $(BUILD_DIR)/netchesszx_direct_session_parity_next_test.exe
SESSION_DIRECT_PARITY_TEST_SRC := tests/session/test_direct_session_parity.c \
                                  tests/session/direct_reference_runner.c \
                                  tests/spectrum/text_asm_host.c \
                                  src/common/session/session.c \
                                  src/common/session/direct_session.c \
                                  src/common/session/mqtt_session.c \
                                  src/common/chess/move_coords.c \
                                  src/common/chess/legal.c \
                                  src/common/protocol/direct_session_protocol.c \
                                  src/common/protocol/mqtt_session_protocol_format.c \
                                  src/common/protocol/game_protocol.c \
                                  src/common/protocol/game_protocol_extra.c \
                                  src/common/protocol/game_protocol_format.c \
                                  src/common/protocol/mqtt_session_protocol.c \
                                  src/spectrum/config/session.c \
                                  src/spectrum/session/direct.c \
                                  src/spectrum/session/event.c \
                                  src/spectrum/overlay/control_ovl.c \
                                  src/spectrum/session/mqtt.c \
                                  src/spectrum/session/outgoing.c \
                                  src/spectrum/session/ping.c \
                                  src/spectrum/session/poll.c \
                                  src/spectrum/transport/keepalive_protocol.c \
                                  src/spectrum/overlay/restore_ovl.c \
                                  src/spectrum/board/board.c \
                                  src/spectrum/board/san.c \
                                  src/common/chess/rules_compact.c
KEEPALIVE_PROTOCOL_TEST := $(BUILD_DIR)/netchesszx_keepalive_protocol_test.exe
KEEPALIVE_PROTOCOL_TEST_SRC := src/spectrum/transport/keepalive_protocol.c \
                               src/common/protocol/game_protocol.c \
                               tests/net/test_keepalive_protocol.c
SESSION_CONFIG_TEST := $(BUILD_DIR)/netchesszx_session_config_test.exe
SESSION_CONFIG_TEST_SRC := src/spectrum/config/session.c \
                           src/common/protocol/game_protocol.c \
                           tests/spectrum/test_session_config.c
SESSION_PING_TEST := $(BUILD_DIR)/netchesszx_session_ping_test.exe
SESSION_PING_TEST_SRC := src/spectrum/session/ping.c tests/spectrum/test_session_ping.c
SESSION_PING_NEXT_TEST := $(BUILD_DIR)/netchesszx_session_ping_next_test.exe
SESSION_POLL_TEST := $(BUILD_DIR)/netchesszx_session_poll_test.exe
SESSION_POLL_TEST_SRC := src/spectrum/config/session.c \
                          src/common/protocol/direct_session_protocol.c \
                          src/common/protocol/game_protocol.c \
                          src/common/protocol/game_protocol_extra.c \
                          src/common/protocol/mqtt_session_protocol.c \
                         src/spectrum/transport/keepalive_protocol.c \
                         src/spectrum/session/mqtt.c src/spectrum/session/event.c \
                         src/spectrum/overlay/control_ovl.c \
                         src/spectrum/session/ping.c src/spectrum/session/poll.c \
                         tests/spectrum/test_session_poll.c
SESSION_DIRECT_TEST := $(BUILD_DIR)/netchesszx_session_direct_test.exe
SESSION_DIRECT_TEST_SRC := src/spectrum/config/session.c \
                            src/common/protocol/direct_session_protocol.c \
                            src/common/protocol/game_protocol.c \
                            src/spectrum/session/direct.c \
                            tests/spectrum/test_session_direct.c
SESSION_EVENT_TEST := $(BUILD_DIR)/netchesszx_session_event_test.exe
SESSION_EVENT_TEST_SRC := src/spectrum/config/session.c \
                           src/common/protocol/direct_session_protocol.c \
                           src/common/protocol/game_protocol.c \
                           src/common/protocol/game_protocol_extra.c \
                           src/common/protocol/mqtt_session_protocol.c \
                          src/spectrum/transport/keepalive_protocol.c \
                          src/spectrum/session/mqtt.c src/spectrum/session/event.c \
                          src/spectrum/overlay/control_ovl.c \
                          tests/spectrum/test_session_event.c
SESSION_MQTT_TEST := $(BUILD_DIR)/netchesszx_session_mqtt_test.exe
SESSION_MQTT_TEST_SRC := src/spectrum/config/session.c \
                         src/common/protocol/game_protocol.c \
                         src/common/protocol/mqtt_session_protocol.c \
                         src/spectrum/session/mqtt.c \
                         tests/spectrum/test_session_mqtt.c
SESSION_SPECTRUM_PAIR_TEST := $(BUILD_DIR)/netchesszx_session_spectrum_pair_test.exe
SESSION_SPECTRUM_PAIR_TEST_SRC := src/spectrum/config/session.c \
                                  src/common/protocol/direct_session_protocol.c \
                                  src/common/protocol/game_protocol.c \
                                  src/common/protocol/mqtt_session_protocol.c \
                                  src/common/protocol/mqtt_session_protocol_format.c \
                                  src/spectrum/session/direct.c \
                                  src/spectrum/session/mqtt.c \
                                  tests/spectrum/test_session_spectrum_pair.c
SESSION_OUTGOING_TEST := $(BUILD_DIR)/netchesszx_session_outgoing_test.exe
SESSION_OUTGOING_TEST_SRC := src/common/protocol/game_protocol.c \
                             src/spectrum/config/session.c \
                             src/spectrum/session/outgoing.c \
                             tests/spectrum/text_asm_host.c \
                             tests/spectrum/test_session_outgoing.c
ZX_TAP := $(RELEASE_DIR)/$(ZX_NAME).tap
ZX_OVL := $(RELEASE_DIR)/$(ZX_NAME).OVL
ZX_DAT := $(RELEASE_DIR)/$(ZX_NAME).DAT
BUILD_DAT := $(BUILD_DIR)/$(ZX_NAME).DAT
OVL_DEFS := $(BUILD_DIR)/overlay_defs.asm
OVL_ATLAS_TABLE := $(BUILD_DIR)/overlay_atlas_table.asm
ABI_MANIFEST := $(BUILD_DIR)/abi_manifest.json
ABI_BASELINE := docs/abi_manifest.baseline.json
NEXT_ABI_MANIFEST = $(NEXT_NEX_BUILD_DIR)/abi_manifest.json
NEXT_ABI_BASELINE := docs/abi_manifest.next.baseline.json
ABI_HEADERS := src/spectrum/overlay/overlay_api.h \
               src/spectrum/overlay/overlay_context.h \
               src/spectrum/overlay/overlay.h \
               src/spectrum/ui/info_panel.h \
               src/spectrum/render_status.h \
               src/spectrum/lowram_map.h \
               src/common/session/session.h
SIZE_REPORT := $(BUILD_DIR)/size_report.json
SIZE_BASELINE := docs/size_report.baseline.json
LITERAL_REPORT := $(BUILD_DIR)/literal_report.json
ZX_BUILD_LOG := $(BUILD_DIR)/$(ZX_NAME).build.log

ZX_TARGET_CFLAGS ?=
UART_BACKEND ?= divmmc
ifeq ($(UART_BACKEND),next)
DAT_PLATFORM_FLAG := --next
else
DAT_PLATFORM_FLAG :=
endif
UART_ASM := asm/uart/$(UART_BACKEND)_uart.asm
SCREEN_ASM ?= asm/spectrum/screen.asm
OVERLAY_LOADER_ASM ?= asm/esxdos/overlay_loader.asm
SHRINK_ASM := asm/spectrum/shrink_kernels.asm
ESX_COMMON_ASM := asm/esxdos/esx_fileio_spectalk.asm
ESX_FILEUI_ASM := asm/esxdos/esx_fileui.asm
ESX_SAVELOAD_ASM := asm/esxdos/esx_saveload.asm

NEXT_OVERLAY_LOADER_ASM := asm/next/overlay_loader_next.asm
NEXT_GRAPHICS_BANK_ASM := asm/next/graphics_bank_next.asm
NEXT_GRAPHICS_BANK_LAYOUT := asm/next/graphics_bank_layout.asm
NEXT_NEX_BUILD_DIR := $(BUILD_DIR)/nex
NEXT_NEX_STAGE_DIR := $(NEXT_NEX_BUILD_DIR)/stage
NEXT_NEX_RELEASE_DIR := release/Next
NEXT_SIZE_REPORT := $(NEXT_NEX_BUILD_DIR)/size_report.json
NEXT_GRAPHICS_BANK_DEFS := $(NEXT_NEX_BUILD_DIR)/next_graphics_defs.asm
NEXT_GRAPHICS_BANK_OBJ := $(NEXT_NEX_BUILD_DIR)/asm/next/graphics_bank_next.o
NEXT_GRAPHICS_BANK_BIN := $(NEXT_NEX_BUILD_DIR)/SHATRANJ_GRAPHICS.BIN
NEXT_GRAPHICS_BANK_ORG := 0x0200
NEXT_GRAPHICS_BANK_OFFSET := 57856
NEXT_GRAPHICS_BANK_LIMIT := 7680
NEXT_ZX0 ?= z88dk-zx0
NEXT_BUNDLE_BANK_BASE := 8
NEXT_RAW_BANK_BASE := 16
NEXT_MAX_BUNDLE_BANKS := 3
NEXT_BUNDLE_DAT_OFFSET := 32768
NEXT_SPRITE_BIN := assets/next/lichess_piece_sprites.bin
NEXT_SPRITE_PALETTE_ASM := assets/next/lichess_sprite_palette.asm
NEXT_SPRITE_PAL_BIN := assets/next/lichess_sprite_palette.bin
NEXT_SPRITE_META := assets/next/lichess_piece_sprites.json
NEXT_SPRITE_OFFSET := 40960
NEXT_SPRITE_PAL_OFFSET := 53760
NEXT_ABOUT_NXI_SRC := assets/next/about_screen.nxi
NEXT_ABOUT_NXI := $(NEXT_NEX_BUILD_DIR)/about_screen_baked.nxi
NEXT_ABOUT_PAL_OFFSET := 57344
NEXT_ABOUT_PIXELS_OFFSET := 65536
ZX_NEX := $(NEXT_NEX_RELEASE_DIR)/$(ZX_NAME).nex

ZX_CLIB := sdcc_iy
ZX_ASMFLAGS := -DNETCHESSZX_SDCC_IY
# The .nex banking build (Next loader) also flags standalone-assembled ASM
# (overlays) so IFDEF NETCHESSZX_NEXT picks the Next variants there too.
ifeq ($(OVERLAY_LOADER_ASM),$(NEXT_OVERLAY_LOADER_ASM))
ZX_ASMFLAGS += -DNETCHESSZX_NEXT
endif
ZX_SDCC_CFLAGS := -compiler=sdcc -Cs--no-reg-params --opt-code-size --fomit-frame-pointer \
                  -DNETCHESSZX_SDCC_IY \
                  -Ca$(ZX_ASMFLAGS)
ZX_LDFLAGS := -Wl,--gc-sections
ZX_Z80ASM := $(Z80ASM) $(ZX_ASMFLAGS)

ZX_CFLAGS := -vn -startup=31 -clib=$(ZX_CLIB) -SO3 -m \
             -custom-copt-rules=$(BUILD_DIR_UP)tools/netchesszx_bool_copt \
             $(ZX_SDCC_CFLAGS) \
             -Ca-I$(patsubst %/,%,$(BUILD_DIR_UP)) \
             -I$(BUILD_DIR_UP)src \
             -pragma-define:CLIB_MALLOC_HEAP_SIZE=0 \
             -pragma-define:CLIB_STDIO_HEAP_SIZE=0 \
             -pragma-define:CRT_ENABLE_STDIO=0 \
             -pragma-define:CRT_ENABLE_EIDI=0 \
             -pragma-define:CRT_STACK_SIZE=512 \
              -DNETCHESSZX_FIXED_LOW_RAM \
             -zorg=$(ZX_ORG) \
             -DNETCHESSZX_PORT=$(PORT) \
             -DNETCHESSZX_MQTT_HOST_TOKEN=$(MQTT_HOST) \
             -DNETCHESSZX_MQTT_PORT=$(MQTT_PORT) \
             -DNETCHESSZX_MQTT_CODE_TOKEN=$(MQTT_CODE) \
              $(ZX_LDFLAGS) \
              $(ZX_EXTRA_CFLAGS) \
              $(ZX_TARGET_CFLAGS)
ZX_OVL_CFLAGS := -vn -clib=$(ZX_CLIB) -SO3 -m \
                  $(ZX_SDCC_CFLAGS) \
                  -I$(BUILD_DIR_UP)src \
                -DNETCHESSZX_FIXED_LOW_RAM \
                  $(ZX_EXTRA_CFLAGS) \
                  $(ZX_TARGET_CFLAGS)
MQTT_CONNECT_OVL_CFLAGS := -DNETCHESSZX_MQTT_PORT=$(MQTT_PORT)

.NOTPARALLEL:

.PHONY: all check full-check module-guards layering-check layering-report overlay-cap-check overlay-cap-report overlay-entry-abi-check transport-contract-check mqtt-client-id-check pc-direct-policy-check pc-policy-guard spectrum-direct-policy-check session-boundaries-check test session-core-test session-mqtt-parity-test session-direct-core-test session-direct-parity-test rules-oracle session-spectrum-pair-test tap tap-direct-overlay tap-divmmc tap-next next nex nex-size-report sdcc-iy-contract-check abi-manifest abi-next-manifest abi-baseline abi-next-baseline abi-check abi-next-check size-report size-baseline size-check literal-report client qt-client pc-client mac-client client-msvc client-cmake clean clean-spectrum clean-client FORCE

all: check clean test tap nex client

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(RULES_TEST): $(RULES_TEST_SRC) src/common/chess/position.h src/common/chess/legal.h src/common/chess/rules_compact.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(RULES_TEST_SRC) -o $@

$(MOVE_COORDS_TEST): $(MOVE_COORDS_TEST_SRC) src/common/chess/move_coords.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(MOVE_COORDS_TEST_SRC) -o $@

$(SAVEGAME_WIRE_TEST): $(SAVEGAME_WIRE_TEST_SRC) src/common/savegame/savegame_wire.h src/common/savegame/savegame_format.h src/spectrum/restore/restore.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST -D__z88dk_fastcall= \
		$(SAVEGAME_WIRE_TEST_SRC) -o $@

$(BOARD_TEST): $(BOARD_TEST_SRC) src/spectrum/board/board.h src/spectrum/board/san.h src/common/chess/rules_compact.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST $(BOARD_TEST_SRC) -o $@

$(RULES_COMPACT_PERFT_TEST): $(RULES_COMPACT_PERFT_TEST_SRC) src/spectrum/board/board.h src/common/chess/rules_compact.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST $(RULES_COMPACT_PERFT_TEST_SRC) -o $@

$(MQTT_TEST): $(MQTT_TEST_SRC) src/common/mqtt/mqtt.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(MQTT_TEST_SRC) -o $@

$(MQTT_STREAM_TEST): $(MQTT_STREAM_TEST_SRC) src/spectrum/transport/net.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -Wno-pointer-to-int-cast -DNETCHESSZX_HOST_TEST -D__z88dk_fastcall= \
		$(HOST_GC_CFLAGS) $(MQTT_STREAM_TEST_SRC) $(HOST_GC_LDFLAGS) -o $@


$(GAME_PROTOCOL_TEST): $(GAME_PROTOCOL_TEST_SRC) src/common/protocol/game_protocol.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(GAME_PROTOCOL_TEST_SRC) -o $@

$(ESP_AT_TEST): $(ESP_AT_TEST_SRC) src/spectrum/transport/esp_at.h src/spectrum/platform/net_runtime.h src/spectrum/platform/uart.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST $(ESP_AT_TEST_SRC) -o $@

$(ESP_AT_NEXT_TEST): $(ESP_AT_TEST_SRC) src/spectrum/transport/esp_at.h src/spectrum/platform/net_runtime.h src/spectrum/platform/uart.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -Wno-unused-function -DNETCHESSZX_HOST_TEST -DNETCHESSZX_NEXT $(ESP_AT_TEST_SRC) -o $@

$(UART_PLATFORM_TEST): $(UART_PLATFORM_TEST_SRC) src/spectrum/platform/uart.h src/spectrum/lowram_map.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST $(UART_PLATFORM_TEST_SRC) -o $@

$(DIRECT_IPD_TEST): $(DIRECT_IPD_TEST_SRC) src/spectrum/overlay/direct_ovl.c src/spectrum/overlay/overlay_api.h src/spectrum/transport/net.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST -D__z88dk_fastcall= $(DIRECT_IPD_TEST_SRC) -o $@

$(MQTT_SESSION_PROTOCOL_TEST): $(MQTT_SESSION_PROTOCOL_TEST_SRC) src/common/protocol/mqtt_session_protocol.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(MQTT_SESSION_PROTOCOL_TEST_SRC) -o $@

$(DIRECT_SESSION_PROTOCOL_TEST): $(DIRECT_SESSION_PROTOCOL_TEST_SRC) src/common/protocol/direct_session_protocol.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(DIRECT_SESSION_PROTOCOL_TEST_SRC) -o $@

$(SESSION_CORE_TEST): $(SESSION_CORE_TEST_SRC) src/common/session/session.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_CORE_TEST_SRC) -o $@

session-core-test: $(SESSION_CORE_TEST)
	./$(SESSION_CORE_TEST)

$(SESSION_MQTT_PARITY_TEST): $(SESSION_MQTT_PARITY_TEST_SRC) tests/session/mqtt_session_transcripts.h src/spectrum/app/app.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST -DNETCHESSZX_HOST_SESSION_TEST \
		-D__z88dk_fastcall= $(HOST_GC_CFLAGS) \
		$(SESSION_MQTT_PARITY_TEST_SRC) $(HOST_GC_LDFLAGS) -o $@

session-mqtt-parity-test: $(SESSION_MQTT_PARITY_TEST)
	./$(SESSION_MQTT_PARITY_TEST)

$(SESSION_DIRECT_CORE_TEST): $(SESSION_DIRECT_CORE_TEST_SRC) src/common/session/session.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_DIRECT_CORE_TEST_SRC) -o $@

session-direct-core-test: $(SESSION_DIRECT_CORE_TEST)
	./$(SESSION_DIRECT_CORE_TEST)

$(SESSION_DIRECT_PARITY_TEST): $(SESSION_DIRECT_PARITY_TEST_SRC) tests/session/direct_parity.h src/spectrum/app/app.c src/spectrum/overlay/direct_ovl.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST -DNETCHESSZX_HOST_SESSION_TEST \
		-D__z88dk_fastcall= $(HOST_GC_CFLAGS) \
		$(SESSION_DIRECT_PARITY_TEST_SRC) $(HOST_GC_LDFLAGS) -o $@

$(SESSION_DIRECT_PARITY_NEXT_TEST): $(SESSION_DIRECT_PARITY_TEST_SRC) tests/session/direct_parity.h src/spectrum/app/app.c src/spectrum/overlay/direct_ovl.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_HOST_TEST -DNETCHESSZX_HOST_SESSION_TEST \
		-DNETCHESSZX_NEXT -DNETCHESSZX_NEXT_BANKING \
		-D__z88dk_fastcall= $(HOST_GC_CFLAGS) \
		$(SESSION_DIRECT_PARITY_TEST_SRC) $(HOST_GC_LDFLAGS) -o $@

session-direct-parity-test: $(SESSION_DIRECT_PARITY_TEST)
	./$(SESSION_DIRECT_PARITY_TEST)

$(KEEPALIVE_PROTOCOL_TEST): $(KEEPALIVE_PROTOCOL_TEST_SRC) src/spectrum/transport/keepalive_protocol.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(KEEPALIVE_PROTOCOL_TEST_SRC) -o $@

$(SESSION_CONFIG_TEST): $(SESSION_CONFIG_TEST_SRC) src/spectrum/config/session.h src/spectrum/transport/net.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_CONFIG_TEST_SRC) -o $@

$(SESSION_PING_TEST): $(SESSION_PING_TEST_SRC) src/spectrum/session/ping.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_PING_TEST_SRC) -o $@

$(SESSION_PING_NEXT_TEST): $(SESSION_PING_TEST_SRC) src/spectrum/session/ping.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -DNETCHESSZX_NEXT $(SESSION_PING_TEST_SRC) -o $@

$(SESSION_POLL_TEST): $(SESSION_POLL_TEST_SRC) src/spectrum/config/session.h src/spectrum/session/poll.h src/spectrum/session/ping.h src/spectrum/session/event.h src/spectrum/transport/link.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_POLL_TEST_SRC) -o $@

$(SESSION_DIRECT_TEST): $(SESSION_DIRECT_TEST_SRC) src/spectrum/config/session.h src/spectrum/session/direct.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_DIRECT_TEST_SRC) -o $@

$(SESSION_EVENT_TEST): $(SESSION_EVENT_TEST_SRC) src/spectrum/config/session.h src/spectrum/session/event.h src/spectrum/session/mqtt.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_EVENT_TEST_SRC) -o $@

$(SESSION_MQTT_TEST): $(SESSION_MQTT_TEST_SRC) src/spectrum/config/session.h src/spectrum/session/mqtt.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_MQTT_TEST_SRC) -o $@

$(SESSION_SPECTRUM_PAIR_TEST): $(SESSION_SPECTRUM_PAIR_TEST_SRC) src/spectrum/config/session.h src/spectrum/session/direct.h src/spectrum/session/mqtt.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_SPECTRUM_PAIR_TEST_SRC) -o $@

$(SESSION_OUTGOING_TEST): $(SESSION_OUTGOING_TEST_SRC) src/spectrum/config/session.h src/spectrum/session/outgoing.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SESSION_OUTGOING_TEST_SRC) -o $@

module-guards: layering-check overlay-cap-check overlay-entry-abi-check transport-contract-check mqtt-client-id-check pc-direct-policy-check spectrum-direct-policy-check session-boundaries-check

layering-check: tools/check_layering.py docs/overlay_state_allowlist.json
	$(PYTHON) tools/check_layering.py --root . --overlay-state-allowlist docs/overlay_state_allowlist.json

layering-report: tools/check_layering.py docs/overlay_state_allowlist.json
	$(PYTHON) tools/check_layering.py --root . --overlay-state-allowlist docs/overlay_state_allowlist.json --report

overlay-cap-check: tools/check_overlay_caps.py docs/overlay_capabilities.json tools/gen_overlay_defs.py tests/tools/test_overlay_caps.py
	$(PYTHON) tools/check_overlay_caps.py --root . --policy docs/overlay_capabilities.json
	$(PYTHON) tests/tools/test_overlay_caps.py

overlay-cap-report: tools/check_overlay_caps.py docs/overlay_capabilities.json tools/gen_overlay_defs.py
	$(PYTHON) tools/check_overlay_caps.py --root . --policy docs/overlay_capabilities.json --report

overlay-entry-abi-check: tools/check_overlay_entry_abi.py
	$(PYTHON) tools/check_overlay_entry_abi.py --root .

transport-contract-check: tools/check_transport_contract.py src/spectrum/transport/link.h src/spectrum/transport/net.c src/sprinter/transport/unet_link.c
	$(PYTHON) tools/check_transport_contract.py --root .

mqtt-client-id-check: tools/check_mqtt_client_id.py src/pc/client/main_window.cpp src/spectrum/config/session.h asm/overlay/mqtt_connect/entry_mqtt_connect.asm
	$(PYTHON) tools/check_mqtt_client_id.py --root .

pc-direct-policy-check: tools/check_pc_direct_policy.py
	$(PYTHON) tools/check_pc_direct_policy.py --root .

pc-policy-guard: pc-direct-policy-check

spectrum-direct-policy-check: tools/check_spectrum_direct_policy.py
	$(PYTHON) tools/check_spectrum_direct_policy.py --root .

session-boundaries-check: tools/check_session_boundaries.py tests/session/mqtt_session_transcripts.h tests/session/mqtt_session_transcripts.c tests/session/test_mqtt_session_parity.c tests/session/direct_parity.h tests/session/test_direct_session_parity.c src/spectrum/transport/mqtt_session_wire.c src/common/session/session.c src/common/session/session.h src/pc/client/direct_session_adapter.cpp src/pc/client/mqtt_session_adapter.cpp
	$(PYTHON) tools/check_session_boundaries.py --root .

check: module-guards | $(BUILD_DIR) $(RELEASE_DIR)
	@fail=0; \
	for t in $(ZCC) $(Z80ASM) z88dk-appmake grep sed head wc dd $(PYTHON); do \
		command -v "$$t" >/dev/null 2>&1 || { echo "[ERR] Missing tool: $$t"; fail=1; }; \
	done; \
	for f in $(SPECTRUM_SRC) $(UART_ASM) $(SHRINK_ASM) $(SCREEN_ASM) asm/spectrum/text.asm $(OVERLAY_LOADER_ASM) $(PIECE_ASM) tools/gen_overlay_defs.py; do \
		test -f "$$f" || { echo "[ERR] Missing source: $$f"; fail=1; }; \
	done; \
	exit $$fail

test: $(RULES_TEST) $(MOVE_COORDS_TEST) $(SAVEGAME_WIRE_TEST) $(BOARD_TEST) $(RULES_COMPACT_PERFT_TEST) $(MQTT_TEST) $(MQTT_STREAM_TEST) $(GAME_PROTOCOL_TEST) $(MQTT_SESSION_PROTOCOL_TEST) $(DIRECT_SESSION_PROTOCOL_TEST) $(SESSION_CORE_TEST) $(SESSION_MQTT_PARITY_TEST) $(SESSION_DIRECT_CORE_TEST) $(SESSION_DIRECT_PARITY_TEST) $(SESSION_DIRECT_PARITY_NEXT_TEST) $(KEEPALIVE_PROTOCOL_TEST) $(ESP_AT_TEST) $(ESP_AT_NEXT_TEST) $(UART_PLATFORM_TEST) $(DIRECT_IPD_TEST) $(SESSION_CONFIG_TEST) $(SESSION_PING_TEST) $(SESSION_PING_NEXT_TEST) $(SESSION_POLL_TEST) $(SESSION_DIRECT_TEST) $(SESSION_EVENT_TEST) $(SESSION_MQTT_TEST) $(SESSION_OUTGOING_TEST) tests/tools/test_gen_assets_about.py tests/tools/test_next_flip_sprite_slots.py tests/tools/test_next_graphics_bank.py tests/tools/test_next_board_theme_rgb333.py tests/tools/test_tap_image.py
	"$(PYTHON)" -m unittest discover -s tests/tools -p "test_gen_assets_about.py"
	"$(PYTHON)" tests/tools/test_tap_image.py
	"$(PYTHON)" tests/tools/test_next_flip_sprite_slots.py
	"$(PYTHON)" tests/tools/test_next_graphics_bank.py
	"$(PYTHON)" tests/tools/test_next_board_theme_rgb333.py
	./$(RULES_TEST)
	./$(MOVE_COORDS_TEST)
	./$(SAVEGAME_WIRE_TEST)
	./$(BOARD_TEST)
	./$(RULES_COMPACT_PERFT_TEST)
	./$(MQTT_TEST)
	./$(MQTT_STREAM_TEST)
	./$(ESP_AT_TEST)
	./$(ESP_AT_NEXT_TEST)
	./$(UART_PLATFORM_TEST)
	./$(DIRECT_IPD_TEST)
	./$(GAME_PROTOCOL_TEST)
	./$(MQTT_SESSION_PROTOCOL_TEST)
	./$(DIRECT_SESSION_PROTOCOL_TEST)
	./$(SESSION_CORE_TEST)
	./$(SESSION_MQTT_PARITY_TEST)
	./$(SESSION_DIRECT_CORE_TEST)
	./$(SESSION_DIRECT_PARITY_TEST)
	./$(SESSION_DIRECT_PARITY_NEXT_TEST)
	./$(KEEPALIVE_PROTOCOL_TEST)
	./$(SESSION_CONFIG_TEST)
	./$(SESSION_PING_TEST)
	./$(SESSION_PING_NEXT_TEST)
	./$(SESSION_POLL_TEST)
	./$(SESSION_DIRECT_TEST)
	./$(SESSION_EVENT_TEST)
	./$(SESSION_MQTT_TEST)
	./$(SESSION_OUTGOING_TEST)

rules-oracle: $(RULES_COMPACT_PERFT_TEST)
	"$(PYTHON)" tests/spectrum/rules_compact_pychess_oracle.py $(RULES_ORACLE_ARGS)

session-spectrum-pair-test: $(SESSION_SPECTRUM_PAIR_TEST)
	./$(SESSION_SPECTRUM_PAIR_TEST)

tap: check
tap: $(ZX_TAP)
tap: $(ZX_OVL)
tap: $(ZX_DAT)
tap: move-listings

# zcc drops .c.asm listings next to the sources; sweep them into
# $(BUILD_DIR)/listings so src/ stays clean (shrink sessions read them there).
move-listings: $(ZX_TAP) $(ZX_OVL)
	@mkdir -p $(BUILD_DIR)/listings
	@find src -name '*.c.asm' -exec sh -c 'mkdir -p "$(BUILD_DIR)/listings/$$(dirname "$$1")" && mv -f "$$1" "$(BUILD_DIR)/listings/$$1"' _ {} \;

.PHONY: move-listings

tap-divmmc:
	$(MAKE) UART_BACKEND=divmmc tap

tap-next:
	$(MAKE) UART_BACKEND=next ZX_TARGET_CFLAGS='-DNETCHESSZX_NEXT' BUILD_DIR=$(BUILD_DIR)/next RELEASE_DIR=$(BUILD_DIR)/next/stage tap

nex: $(ZX_NEX)

$(NEXT_SPRITE_BIN) $(NEXT_SPRITE_PALETTE_ASM) $(NEXT_SPRITE_PAL_BIN) $(NEXT_SPRITE_META): tools/build_next_piece_sprites.py assets/lichess/selected_next_sets.json assets/lichess/selected_next_boards.json
	$(PYTHON) tools/build_next_piece_sprites.py

$(ZX_NEX): FORCE tools/gen_next_nex.py tools/gen_next_graphics_defs.py tools/next_bundle_codec.py tests/tools/test_next_bundle_codec.py tests/tools/test_next_graphics_bank.py tests/tools/test_next_board_theme_rgb333.py tools/make_about_nxi.py $(NEXT_OVERLAY_LOADER_ASM) $(NEXT_GRAPHICS_BANK_ASM) $(NEXT_GRAPHICS_BANK_LAYOUT) asm/uart/next_uart.asm $(NEXT_SPRITE_BIN) $(NEXT_SPRITE_PAL_BIN) $(NEXT_ABOUT_NXI_SRC)
	rm -rf $(NEXT_NEX_BUILD_DIR) $(NEXT_NEX_RELEASE_DIR)
	$(MAKE) UART_BACKEND=next OVERLAY_LOADER_ASM=$(NEXT_OVERLAY_LOADER_ASM) SCREEN_ASM=asm/spectrum/screen.asm ZX_TARGET_CFLAGS='-DNETCHESSZX_NEXT -DNETCHESSZX_NEXT_BANKING -Ca-DNETCHESSZX_NEXT' BUILD_DIR=$(NEXT_NEX_BUILD_DIR) RELEASE_DIR=$(NEXT_NEX_STAGE_DIR) tap
	$(PYTHON) tools/make_about_nxi.py $(NEXT_ABOUT_NXI_SRC) $(ASSET_ASM) $(NEXT_ABOUT_NXI)
	$(PYTHON) tests/tools/test_next_bundle_codec.py --zx0 "$(NEXT_ZX0)"
	$(PYTHON) tests/tools/test_next_graphics_bank.py
	$(PYTHON) tests/tools/test_next_board_theme_rgb333.py
	$(PYTHON) tools/gen_next_graphics_defs.py $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME).map > $(NEXT_GRAPHICS_BANK_DEFS)
	rm -f $(NEXT_GRAPHICS_BANK_OBJ) $(NEXT_GRAPHICS_BANK_DEFS:.asm=.o)
	$(ZX_Z80ASM) -O=$(NEXT_NEX_BUILD_DIR) $(NEXT_GRAPHICS_BANK_ASM)
	$(ZX_Z80ASM) -b -r$(NEXT_GRAPHICS_BANK_ORG) -o=$(NEXT_GRAPHICS_BANK_BIN) $(NEXT_GRAPHICS_BANK_OBJ) $(NEXT_GRAPHICS_BANK_DEFS)
	@graphics_size=$$(wc -c < $(NEXT_GRAPHICS_BANK_BIN)); \
	if [ "$$graphics_size" -gt $(NEXT_GRAPHICS_BANK_LIMIT) ]; then \
		printf "[ERR] Next graphics bank too large: $$graphics_size bytes (max $(NEXT_GRAPHICS_BANK_LIMIT))\n"; \
		exit 1; \
	fi; \
	printf "[OK] Next graphics bank: $$graphics_size/$(NEXT_GRAPHICS_BANK_LIMIT) bytes\n"
	$(PYTHON) tools/gen_next_nex.py --map $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME).map --code-bin $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME)_CODE.bin --ovl $(NEXT_NEX_STAGE_DIR)/$(ZX_NAME).OVL --dat $(NEXT_NEX_STAGE_DIR)/$(ZX_NAME).DAT --out $(ZX_NEX) --org $(ZX_ORG) --bundle-bank-base $(NEXT_BUNDLE_BANK_BASE) --raw-bank-base $(NEXT_RAW_BANK_BASE) --max-bundle-banks $(NEXT_MAX_BUNDLE_BANKS) --zx0 "$(NEXT_ZX0)" --dat-offset $(NEXT_BUNDLE_DAT_OFFSET) --sprite-patterns $(NEXT_SPRITE_BIN) --sprite-offset $(NEXT_SPRITE_OFFSET) --sprite-pal $(NEXT_SPRITE_PAL_BIN) --sprite-pal-offset $(NEXT_SPRITE_PAL_OFFSET) --about-nxi $(NEXT_ABOUT_NXI) --about-pal-offset $(NEXT_ABOUT_PAL_OFFSET) --about-pixels-offset $(NEXT_ABOUT_PIXELS_OFFSET) --graphics-bank $(NEXT_GRAPHICS_BANK_BIN) --graphics-bank-offset $(NEXT_GRAPHICS_BANK_OFFSET) --graphics-bank-org $(NEXT_GRAPHICS_BANK_ORG)

nex-size-report: nex tools/gen_size_report.py
	$(PYTHON) tools/gen_size_report.py --map $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME).map --code-bin $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME)_CODE.bin --tap $(NEXT_NEX_STAGE_DIR)/$(ZX_NAME).tap --ovl $(NEXT_NEX_STAGE_DIR)/$(ZX_NAME).OVL --dat $(NEXT_NEX_STAGE_DIR)/$(ZX_NAME).DAT --overlay-sizes $(NEXT_NEX_BUILD_DIR)/overlay_sizes.json --output $(NEXT_SIZE_REPORT)

next: nex

tap-direct-overlay:
	$(MAKE) tap

sdcc-iy-contract-check: tools/check_sdcc_iy_contract.py | $(BUILD_DIR)
	$(PYTHON) tools/check_sdcc_iy_contract.py --zcc "$(ZCC)" --build-dir "$(BUILD_DIR)"

abi-next-manifest: nex tools/gen_abi_manifest.py tools/gen_overlay_defs.py $(ABI_HEADERS)
	$(PYTHON) tools/gen_abi_manifest.py $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME).map --output $(NEXT_ABI_MANIFEST)

abi-manifest: abi-next-manifest tap tools/gen_abi_manifest.py tools/gen_overlay_defs.py $(ABI_HEADERS) | $(BUILD_DIR)
	$(PYTHON) tools/gen_abi_manifest.py $(BUILD_DIR)/$(ZX_NAME).map --output $(ABI_MANIFEST)

abi-next-baseline: nex tools/gen_abi_manifest.py tools/gen_overlay_defs.py $(ABI_HEADERS)
	$(PYTHON) tools/gen_abi_manifest.py $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME).map --output $(NEXT_ABI_MANIFEST) --write-baseline $(NEXT_ABI_BASELINE)

abi-baseline: abi-next-baseline tap tools/gen_abi_manifest.py tools/gen_overlay_defs.py $(ABI_HEADERS) | $(BUILD_DIR)
	$(PYTHON) tools/gen_abi_manifest.py $(BUILD_DIR)/$(ZX_NAME).map --output $(ABI_MANIFEST) --write-baseline $(ABI_BASELINE)

abi-next-check: nex tools/gen_abi_manifest.py tools/gen_overlay_defs.py $(ABI_HEADERS)
	$(PYTHON) tools/gen_abi_manifest.py $(NEXT_NEX_BUILD_DIR)/$(ZX_NAME).map --output $(NEXT_ABI_MANIFEST) --baseline $(NEXT_ABI_BASELINE) --fail-on-missing-baseline $(ABI_CHECK_FLAGS)

abi-check: abi-next-check tap tools/gen_abi_manifest.py tools/gen_overlay_defs.py $(ABI_HEADERS) | $(BUILD_DIR)
	$(PYTHON) tools/gen_abi_manifest.py $(BUILD_DIR)/$(ZX_NAME).map --output $(ABI_MANIFEST) --baseline $(ABI_BASELINE) --fail-on-missing-baseline $(ABI_CHECK_FLAGS)

size-report: tap tools/gen_size_report.py | $(BUILD_DIR)
	$(PYTHON) tools/gen_size_report.py --map $(BUILD_DIR)/$(ZX_NAME).map --code-bin $(BUILD_DIR)/$(ZX_NAME)_CODE.bin --tap $(ZX_TAP) --ovl $(ZX_OVL) --dat $(ZX_DAT) --overlay-sizes $(BUILD_DIR)/overlay_sizes.json --output $(SIZE_REPORT)

size-baseline: tap tools/gen_size_report.py | $(BUILD_DIR)
	$(PYTHON) tools/gen_size_report.py --map $(BUILD_DIR)/$(ZX_NAME).map --code-bin $(BUILD_DIR)/$(ZX_NAME)_CODE.bin --tap $(ZX_TAP) --ovl $(ZX_OVL) --dat $(ZX_DAT) --overlay-sizes $(BUILD_DIR)/overlay_sizes.json --output $(SIZE_REPORT) --write-baseline $(SIZE_BASELINE)

size-check: tap tools/gen_size_report.py | $(BUILD_DIR)
	$(PYTHON) tools/gen_size_report.py --map $(BUILD_DIR)/$(ZX_NAME).map --code-bin $(BUILD_DIR)/$(ZX_NAME)_CODE.bin --tap $(ZX_TAP) --ovl $(ZX_OVL) --dat $(ZX_DAT) --overlay-sizes $(BUILD_DIR)/overlay_sizes.json --output $(SIZE_REPORT) --baseline $(SIZE_BASELINE) --fail-on-missing-baseline $(SIZE_CHECK_FLAGS)

full-check:
	$(MAKE) module-guards
	$(MAKE) test
	$(MAKE) abi-check size-check nex-size-report

literal-report: tools/gen_literal_report.py | $(BUILD_DIR)
	$(PYTHON) tools/gen_literal_report.py --root . --output $(LITERAL_REPORT)

client:
ifeq ($(CLIENT_BUILD),auto)
ifneq ($(CLIENT_HOST_IS_WINDOWS),)
	@$(MAKE) client-msvc
else
	@$(MAKE) client-cmake
endif
else
	@$(MAKE) client-$(CLIENT_BUILD)
endif

qt-client: client
pc-client: client
mac-client: client

# Shared desktop dev loop. Windows preserves its external MSVC build tree;
# macOS/Linux use the common CMake tree under build/qt-client.
client-test:
ifneq ($(CLIENT_HOST_IS_WINDOWS),)
	cd client && $(CMAKE) --preset msvc && $(CMAKE) --build --preset msvc-release --parallel && ctest --preset msvc-release
else
	@command -v "$(CMAKE)" >/dev/null 2>&1 || { echo "[ERR] Missing cmake: set CMAKE=/path/to/cmake"; exit 1; }
	@command -v "$(CTEST)" >/dev/null 2>&1 || { echo "[ERR] Missing ctest: set CTEST=/path/to/ctest"; exit 1; }
	$(CMAKE) -S client -B "$(CLIENT_CMAKE_BUILD_DIR)" -DCMAKE_BUILD_TYPE="$(CLIENT_CMAKE_CONFIG)" -DBUILD_TESTING=ON $(CLIENT_CMAKE_ARGS)
	$(CMAKE) --build "$(CLIENT_CMAKE_BUILD_DIR)" --config "$(CLIENT_CMAKE_CONFIG)" --parallel
	$(CTEST) --test-dir "$(CLIENT_CMAKE_BUILD_DIR)" -C "$(CLIENT_CMAKE_CONFIG)" --output-on-failure
endif

client-msvc:
	@command -v "$(POWERSHELL)" >/dev/null 2>&1 || { echo "[ERR] Missing PowerShell 7: set POWERSHELL=pwsh or use CLIENT_BUILD=cmake"; exit 1; }
	$(POWERSHELL) -NoLogo -NoProfile -ExecutionPolicy Bypass -File client/build-msvc.ps1 -QtDir "$(CLIENT_MSVC_QT_DIR)" -Config "$(CLIENT_MSVC_CONFIG)" -Generator "$(CLIENT_MSVC_GENERATOR)" -Architecture "$(CLIENT_MSVC_ARCH)" -DeployTimeoutSeconds $(CLIENT_MSVC_DEPLOY_TIMEOUT) -CleanTimeoutSeconds $(CLIENT_MSVC_CLEAN_TIMEOUT)

client-cmake:
	@command -v "$(CMAKE)" >/dev/null 2>&1 || { echo "[ERR] Missing cmake: set CMAKE=/path/to/cmake"; exit 1; }
	$(CMAKE) -S client -B "$(CLIENT_CMAKE_BUILD_DIR)" -DCMAKE_BUILD_TYPE="$(CLIENT_CMAKE_CONFIG)" $(CLIENT_CMAKE_ARGS)
ifeq ($(HOST_UNAME),Darwin)
	$(CMAKE) -E rm -rf "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app"
endif
	$(CMAKE) --build "$(CLIENT_CMAKE_BUILD_DIR)" --config "$(CLIENT_CMAKE_CONFIG)"
ifeq ($(HOST_UNAME),Darwin)
	@command -v "$(MACDEPLOYQT)" >/dev/null 2>&1 || { echo "[ERR] Missing macdeployqt: set MACDEPLOYQT=/path/to/macdeployqt"; exit 1; }
	@command -v "$(CODESIGN)" >/dev/null 2>&1 || { echo "[ERR] Missing codesign: set CODESIGN=/path/to/codesign"; exit 1; }
	@command -v "$(DITTO)" >/dev/null 2>&1 || { echo "[ERR] Missing ditto: set DITTO=/path/to/ditto"; exit 1; }
	@command -v "$(QTPATHS)" >/dev/null 2>&1 || { echo "[ERR] Missing qtpaths: set QTPATHS=/path/to/qtpaths"; exit 1; }
	$(MACDEPLOYQT) "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app" -always-overwrite -no-codesign -no-plugins
	$(CMAKE) -E make_directory \
		"$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/platforms" \
		"$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/styles" \
		"$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/imageformats"
	$(CMAKE) -E copy_if_different "$$($(QTPATHS) --plugin-dir)/platforms/libqcocoa.dylib" "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/platforms/libqcocoa.dylib"
	$(CMAKE) -E copy_if_different "$$($(QTPATHS) --plugin-dir)/styles/libqmacstyle.dylib" "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/styles/libqmacstyle.dylib"
	$(CMAKE) -E copy_if_different "$$($(QTPATHS) --plugin-dir)/imageformats/libqjpeg.dylib" "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/imageformats/libqjpeg.dylib"
	$(MACDEPLOYQT) "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app" -always-overwrite -no-codesign -no-plugins \
		-executable="$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/platforms/libqcocoa.dylib" \
		-executable="$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/styles/libqmacstyle.dylib" \
		-executable="$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app/Contents/PlugIns/imageformats/libqjpeg.dylib"
	$(CODESIGN) --force --deep --sign - "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app"
	$(CODESIGN) --verify --deep --strict "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app"
	$(CMAKE) -E make_directory "$(CLIENT_MAC_APPLICATIONS_DIR)"
	$(CMAKE) -E rm -rf "$(CLIENT_MAC_APPLICATIONS_DIR)/Shatranj.app"
	$(DITTO) "$(CLIENT_CMAKE_BUILD_DIR)/shatranj-client.app" "$(CLIENT_MAC_APPLICATIONS_DIR)/Shatranj.app"
endif


$(RELEASE_DIR):
	mkdir -p $(RELEASE_DIR)

$(BUILD_DAT): tools/gen_assets.py $(ASSET_ASM) $(PIECE_ASM) $(ABOUT_BOARD) $(SCREEN_ASM) $(OVERLAY_LOADER_ASM) VERSION | $(BUILD_DIR)
	$(PYTHON) tools/gen_assets.py $(ASSET_ASM) $(PIECE_ASM) $(SCREEN_ASM) $(OVERLAY_LOADER_ASM) $(ABOUT_BOARD) $(BUILD_DAT) --version $(APP_VERSION) $(DAT_PLATFORM_FLAG)

$(ZX_DAT): $(BUILD_DAT) | $(RELEASE_DIR)
	cp -f $(BUILD_DAT) $(ZX_DAT)

$(OVL_ATLAS_TABLE): tools/gen_overlay_atlas.py | $(BUILD_DIR)
	$(PYTHON) tools/gen_overlay_atlas.py --build-dir $(BUILD_DIR) --name $(ZX_NAME) --out $(BUILD_DIR)/$(ZX_NAME).OVL.bootstrap --asm-out $(OVL_ATLAS_TABLE) --bootstrap-asm

$(ZX_TAP): FORCE $(SPECTRUM_SRC) $(UART_ASM) $(SHRINK_ASM) $(SCREEN_ASM) asm/spectrum/text.asm $(OVERLAY_LOADER_ASM) tools/netchesszx_bool_copt tools/check_sdcc_iy_contract.py tools/check_tap_image.py $(BUILD_DAT) $(OVL_ATLAS_TABLE) | $(BUILD_DIR) $(RELEASE_DIR)
	rm -f $(BUILD_DIR)/$(ZX_NAME) $(BUILD_DIR)/$(ZX_NAME).tap $(BUILD_DIR)/$(ZX_NAME)_CODE.bin $(BUILD_DIR)/$(ZX_NAME).map
	rm -f $(BUILD_DIR)/NCHESSZX $(BUILD_DIR)/NCHESSZX.tap $(BUILD_DIR)/NCHESSZX_CODE.bin $(BUILD_DIR)/NCHESSZX.map
	rm -f $(RELEASE_DIR)/NCHESSZX.tap $(RELEASE_DIR)/NCHESSZX.OVL $(RELEASE_DIR)/NCHESSZX.DAT
	@{ cd $(BUILD_DIR) && $(ZCC) +zx $(ZX_CFLAGS) $(addprefix $(BUILD_DIR_UP),$(SPECTRUM_SRC)) $(BUILD_DIR_UP)$(UART_ASM) $(BUILD_DIR_UP)$(SHRINK_ASM) $(BUILD_DIR_UP)$(SCREEN_ASM) $(BUILD_DIR_UP)asm/spectrum/text.asm $(BUILD_DIR_UP)$(OVERLAY_LOADER_ASM) -o $(ZX_NAME) -create-app; printf "%s\n" $$? > $(ZX_NAME).build.status; } 2>&1 | tee $(ZX_BUILD_LOG); \
	build_rc=$$(cat $(BUILD_DIR)/$(ZX_NAME).build.status 2>/dev/null || echo 1); \
	rm -f $(BUILD_DIR)/$(ZX_NAME).build.status; \
	if [ "$$build_rc" -ne 0 ]; then exit $$build_rc; fi
	@$(MAKE) sdcc-iy-contract-check
	$(PYTHON) tools/check_lowmem_layout.py --map $(BUILD_DIR)/$(ZX_NAME).map
	cp -f $(BUILD_DIR)/$(ZX_NAME).tap $(ZX_TAP)
	$(PYTHON) tools/check_tap_image.py --map $(BUILD_DIR)/$(ZX_NAME).map --code-bin $(BUILD_DIR)/$(ZX_NAME)_CODE.bin --tap $(ZX_TAP) --org $(ZX_ORG)

$(ZX_OVL): $(ZX_TAP) asm/overlay/rules/entry_rules.asm asm/overlay/rules/rules_stub.asm asm/overlay/board/entry_board.asm asm/overlay/board/helpers.asm src/spectrum/overlay/board_apply_ovl.c asm/overlay/gui_log/entry_gui_log.asm src/spectrum/overlay/gui_log_ovl.c asm/overlay/input_edit/entry_input_edit.asm src/spectrum/overlay/input_edit_ovl.c asm/overlay/mqtt_connect/entry_mqtt_connect.asm src/spectrum/overlay/mqtt_connect_ovl.c asm/overlay/mqtt_tx/entry_mqtt_tx.asm src/spectrum/overlay/mqtt_tx_ovl.c asm/overlay/direct/entry_direct.asm src/spectrum/overlay/direct_ovl.c asm/overlay/menu_config/entry_menu_config.asm asm/overlay/menu_logic/entry_menu_logic.asm src/spectrum/overlay/status_ovl.c asm/overlay/fileui/entry_fileui.asm src/spectrum/overlay/fileui_ovl.c asm/overlay/setup/entry_setup.asm asm/overlay/saveload/entry_saveload.asm src/spectrum/overlay/saveload_ovl.c asm/overlay/restore/entry_restore.asm src/spectrum/overlay/restore_ovl.c asm/overlay/about/entry_about.asm asm/overlay/control/entry_control.asm src/spectrum/overlay/control_ovl.c $(ESX_COMMON_ASM) $(ESX_FILEUI_ASM) $(ESX_SAVELOAD_ASM) tools/gen_overlay_defs.py tools/gen_overlay_atlas.py src/spectrum/overlay/overlay_api.h | $(BUILD_DIR) $(RELEASE_DIR)
	@SLOT=$$(grep '_overlay_code_slot ' $(BUILD_DIR)/$(ZX_NAME).map | sed -n 's/.*= \$$\([0-9A-Fa-f]*\).*/\1/p' | head -1); \
	if [ -z "$$SLOT" ]; then \
		printf "[ERR] _overlay_code_slot not found in $(BUILD_DIR)/$(ZX_NAME).map\n"; \
		exit 1; \
	fi; \
	echo "  overlay_code_slot = 0x$$SLOT"; \
	$(PYTHON) tools/gen_overlay_defs.py $(BUILD_DIR)/$(ZX_NAME).map > $(OVL_DEFS) || exit 1; \
	echo "  overlay_defs.asm generated"; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) asm/overlay/rules/entry_rules.asm 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/rules/rules_stub.asm 2>&1 || exit 1; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_RULES.OVL \
		asm/overlay/rules/entry_rules.o asm/overlay/rules/rules_stub.o $(OVL_DEFS) 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/board/entry_board.asm 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/board/helpers.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/board_apply_ovl.c -o board_apply_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_BOARD.OVL \
		asm/overlay/board/entry_board.o asm/overlay/board/helpers.o $(BUILD_DIR)/board_apply_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/gui_log/entry_gui_log.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/gui_log_ovl.c -o gui_log_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_GUI_LOG.OVL \
		asm/overlay/gui_log/entry_gui_log.o $(BUILD_DIR)/gui_log_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/input_edit/entry_input_edit.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/input_edit_ovl.c -o input_edit_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_INPUT_EDIT.OVL \
		asm/overlay/input_edit/entry_input_edit.o $(BUILD_DIR)/input_edit_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/mqtt_connect/entry_mqtt_connect.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) $(MQTT_CONNECT_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/mqtt_connect_ovl.c -o mqtt_connect_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_MQTT_CONNECT.OVL \
		asm/overlay/mqtt_connect/entry_mqtt_connect.o $(BUILD_DIR)/mqtt_connect_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/mqtt_tx/entry_mqtt_tx.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/mqtt_tx_ovl.c -o mqtt_tx_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_MQTT_TX.OVL \
		asm/overlay/mqtt_tx/entry_mqtt_tx.o $(BUILD_DIR)/mqtt_tx_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	$(ZX_Z80ASM) asm/overlay/direct/entry_direct.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/direct_ovl.c -o direct_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_DIRECT.OVL \
		asm/overlay/direct/entry_direct.o $(BUILD_DIR)/direct_ovl.o $(OVL_DEFS) 2>&1 || exit 1
	@SLOT=$$(grep '_overlay_code_slot ' $(BUILD_DIR)/$(ZX_NAME).map | sed -n 's/.*= \$$\([0-9A-Fa-f]*\).*/\1/p' | head -1); \
	ovl_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_RULES.OVL); \
	hints_size=0; \
	board_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_BOARD.OVL); \
	gui_log_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_GUI_LOG.OVL); \
	input_edit_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_INPUT_EDIT.OVL); \
	mqtt_connect_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_MQTT_CONNECT.OVL); \
	mqtt_tx_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_MQTT_TX.OVL); \
	direct_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_DIRECT.OVL); \
	$(ZX_Z80ASM) asm/overlay/menu_config/entry_menu_config.asm 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_MENU_CONFIG.OVL \
		asm/overlay/menu_config/entry_menu_config.o $(OVL_DEFS) 2>&1 || exit 1; \
	menu_config_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_MENU_CONFIG.OVL); \
	$(ZX_Z80ASM) asm/overlay/menu_logic/entry_menu_logic.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/status_ovl.c -o status_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_MENU_LOGIC.OVL \
		asm/overlay/menu_logic/entry_menu_logic.o $(BUILD_DIR)/status_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	menu_logic_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_MENU_LOGIC.OVL); \
	$(ZX_Z80ASM) asm/overlay/fileui/entry_fileui.asm 2>&1 || exit 1; \
	$(ZX_Z80ASM) $(ESX_FILEUI_ASM) 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/fileui_ovl.c -o fileui_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_FILEUI.OVL \
		asm/overlay/fileui/entry_fileui.o $(BUILD_DIR)/fileui_ovl.o asm/esxdos/esx_fileui.o $(OVL_DEFS) 2>&1 || exit 1; \
	fileui_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_FILEUI.OVL); \
	$(ZX_Z80ASM) asm/overlay/setup/entry_setup.asm 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_SETUP.OVL \
		asm/overlay/setup/entry_setup.o $(OVL_DEFS) 2>&1 || exit 1; \
	setup_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_SETUP.OVL); \
	$(ZX_Z80ASM) asm/overlay/saveload/entry_saveload.asm 2>&1 || exit 1; \
	$(ZX_Z80ASM) $(ESX_SAVELOAD_ASM) 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/saveload_ovl.c -o saveload_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_SAVELOAD.OVL \
		asm/overlay/saveload/entry_saveload.o $(BUILD_DIR)/saveload_ovl.o asm/esxdos/esx_saveload.o $(OVL_DEFS) 2>&1 || exit 1; \
	saveload_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_SAVELOAD.OVL); \
	$(ZX_Z80ASM) asm/overlay/restore/entry_restore.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/restore_ovl.c -o restore_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_RESTORE.OVL \
		asm/overlay/restore/entry_restore.o $(BUILD_DIR)/restore_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	restore_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_RESTORE.OVL); \
	$(ZX_Z80ASM) asm/overlay/about/entry_about.asm 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_ABOUT.OVL \
		asm/overlay/about/entry_about.o $(OVL_DEFS) 2>&1 || exit 1; \
	about_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_ABOUT.OVL); \
	$(ZX_Z80ASM) asm/overlay/control/entry_control.asm 2>&1 || exit 1; \
	(cd $(BUILD_DIR) && $(ZCC) +z80 $(ZX_OVL_CFLAGS) -c $(BUILD_DIR_UP)src/spectrum/overlay/control_ovl.c -o control_ovl.o) 2>&1 || exit 1; \
	rm -f $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~; \
	$(ZX_Z80ASM) -b -r0x$$SLOT -o=$(BUILD_DIR)/$(ZX_NAME)_CONTROL.OVL \
		asm/overlay/control/entry_control.o $(BUILD_DIR)/control_ovl.o $(OVL_DEFS) 2>&1 || exit 1; \
	control_size=$$(wc -c < $(BUILD_DIR)/$(ZX_NAME)_CONTROL.OVL); \
	status_size=0; \
	$(PYTHON) tools/gen_overlay_atlas.py --build-dir $(BUILD_DIR) --name $(ZX_NAME) --out $(ZX_OVL) --asm-out $(OVL_ATLAS_TABLE) --changed-stamp $(BUILD_DIR)/overlay_atlas_table.changed > $(BUILD_DIR)/overlay_sizes.json || exit 1; \
	atlas_changed=$$(cat $(BUILD_DIR)/overlay_atlas_table.changed 2>/dev/null || echo 0); \
	if [ "$$atlas_changed" = "1" ] && [ "$(ATLAS_FINAL)" != "1" ]; then \
		printf "[INFO] overlay atlas table changed; rebuilding resident with baked offsets\\n"; \
		$(MAKE) ATLAS_FINAL=1 $(ZX_OVL) || exit 1; \
		exit 0; \
	fi; \
	if [ "$$atlas_changed" = "1" ] && [ "$(ATLAS_FINAL)" = "1" ]; then \
		printf "[ERR] overlay atlas table changed during final pass\\n"; \
		exit 1; \
	fi; \
	ovl_total=$$(wc -c < $(ZX_OVL)); \
	printf "[OK] $(ZX_NAME).OVL atlas: RULES $$ovl_size bytes, BOARD $$board_size bytes, GUI_LOG $$gui_log_size bytes, INPUT_EDIT $$input_edit_size bytes, MQTT_CONNECT $$mqtt_connect_size bytes, MQTT_TX $$mqtt_tx_size bytes, DIRECT $$direct_size bytes, MENU_CONFIG $$menu_config_size bytes, MENU_LOGIC $$menu_logic_size bytes, HINTS $$hints_size bytes, SETUP $$setup_size bytes, FILEUI $$fileui_size bytes, STATUS $$status_size bytes, SAVELOAD $$saveload_size bytes, RESTORE $$restore_size bytes, ABOUT $$about_size bytes, CONTROL $$control_size bytes, total $$ovl_total bytes\n"
	@rm -f asm/overlay/rules/entry_rules.o asm/overlay/rules/rules_stub.o asm/overlay/board/entry_board.o asm/overlay/board/helpers.o asm/overlay/gui_log/entry_gui_log.o asm/overlay/input_edit/entry_input_edit.o asm/overlay/mqtt_connect/entry_mqtt_connect.o asm/overlay/mqtt_tx/entry_mqtt_tx.o asm/overlay/direct/entry_direct.o asm/overlay/menu_config/entry_menu_config.o asm/overlay/menu_logic/entry_menu_logic.o asm/overlay/fileui/entry_fileui.o asm/overlay/setup/entry_setup.o asm/overlay/saveload/entry_saveload.o asm/overlay/restore/entry_restore.o asm/overlay/about/entry_about.o asm/esxdos/esx_fileio_spectalk.o asm/esxdos/esx_fileui.o asm/esxdos/esx_saveload.o $(BUILD_DIR)/asm/overlay/rules/rules_stub.o $(BUILD_DIR)/board_apply_ovl.o $(BUILD_DIR)/gui_log_ovl.o $(BUILD_DIR)/input_edit_ovl.o $(BUILD_DIR)/mqtt_connect_ovl.o $(BUILD_DIR)/mqtt_tx_ovl.o $(BUILD_DIR)/direct_ovl.o $(BUILD_DIR)/status_ovl.o $(BUILD_DIR)/fileui_ovl.o $(BUILD_DIR)/saveload_ovl.o $(BUILD_DIR)/restore_ovl.o $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~ $(BUILD_DIR)/$(ZX_NAME)_RULES.OVL $(BUILD_DIR)/$(ZX_NAME)_BOARD.OVL $(BUILD_DIR)/$(ZX_NAME)_GUI_LOG.OVL $(BUILD_DIR)/$(ZX_NAME)_INPUT_EDIT.OVL $(BUILD_DIR)/$(ZX_NAME)_MQTT_CONNECT.OVL $(BUILD_DIR)/$(ZX_NAME)_MQTT_TX.OVL $(BUILD_DIR)/$(ZX_NAME)_DIRECT.OVL $(BUILD_DIR)/$(ZX_NAME)_MENU_CONFIG.OVL $(BUILD_DIR)/$(ZX_NAME)_MENU_LOGIC.OVL $(BUILD_DIR)/$(ZX_NAME)_FILEUI.OVL $(BUILD_DIR)/$(ZX_NAME)_SETUP.OVL $(BUILD_DIR)/$(ZX_NAME)_SAVELOAD.OVL $(BUILD_DIR)/$(ZX_NAME)_RESTORE.OVL $(BUILD_DIR)/$(ZX_NAME)_ABOUT.OVL $(BUILD_DIR)/$(ZX_NAME).OVL.tmp $(BUILD_DIR)/overlay_atlas_table.changed $(BUILD_DIR)/$(ZX_NAME).OVL.bootstrap 2>/dev/null || true
	@rm -f asm/overlay/control/entry_control.o $(BUILD_DIR)/control_ovl.o $(BUILD_DIR)/$(ZX_NAME)_CONTROL.OVL

FORCE:

clean: clean-spectrum clean-client clean-sprinter

clean-spectrum:
ifneq ($(CLIENT_HOST_IS_WINDOWS),)
	$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File tools/clean-generated.ps1 -SpectrumOnly
else
	rm -rf $(BUILD_DIR) dist
	rm -rf build-next build-nex release/next release/nex release/Next $(BUILD_DIR)/next $(BUILD_DIR)/nex
	find src -name '*.c.asm' -delete
	rm -f $(RELEASE_DIR)/$(ZX_NAME).tap $(RELEASE_DIR)/$(ZX_NAME).OVL $(RELEASE_DIR)/$(ZX_NAME).DAT
	rm -f $(RELEASE_DIR)/NCHESSZX.tap $(RELEASE_DIR)/NCHESSZX.OVL $(RELEASE_DIR)/NCHESSZX.DAT
	rm -f $(RELEASE_DIR)/$(ZX_NAME)_MQTT_W.tap $(RELEASE_DIR)/$(ZX_NAME)_MQTT_W.OVL $(RELEASE_DIR)/$(ZX_NAME)_MQTT_W.DAT
	rm -f $(RELEASE_DIR)/$(ZX_NAME)_MQTT_B.tap $(RELEASE_DIR)/$(ZX_NAME)_MQTT_B.OVL $(RELEASE_DIR)/$(ZX_NAME)_MQTT_B.DAT
	rm -f $(RELEASE_DIR)/MQTTW $(RELEASE_DIR)/MQTTB $(RELEASE_DIR)/MQTTWKEY $(RELEASE_DIR)/MQTTBKEY $(RELEASE_DIR)/ZXCHNET.tap
	rm -f asm/overlay/rules/entry_rules.o asm/overlay/rules/rules_stub.o asm/overlay/board/entry_board.o asm/overlay/board/helpers.o asm/overlay/gui_log/entry_gui_log.o asm/overlay/input_edit/entry_input_edit.o asm/overlay/mqtt_connect/entry_mqtt_connect.o asm/overlay/mqtt_tx/entry_mqtt_tx.o asm/overlay/direct/entry_direct.o asm/overlay/menu_config/entry_menu_config.o asm/overlay/menu_logic/entry_menu_logic.o asm/overlay/fileui/entry_fileui.o asm/overlay/setup/entry_setup.o asm/overlay/saveload/entry_saveload.o asm/overlay/restore/entry_restore.o asm/overlay/about/entry_about.o asm/esxdos/esx_fileio_spectalk.o asm/esxdos/esx_fileui.o asm/esxdos/esx_saveload.o $(BUILD_DIR)/asm/overlay/rules/rules_stub.o $(BUILD_DIR)/board_apply_ovl.o $(BUILD_DIR)/gui_log_ovl.o $(BUILD_DIR)/input_edit_ovl.o $(BUILD_DIR)/mqtt_connect_ovl.o $(BUILD_DIR)/mqtt_tx_ovl.o $(BUILD_DIR)/direct_ovl.o $(BUILD_DIR)/status_ovl.o $(BUILD_DIR)/fileui_ovl.o $(BUILD_DIR)/saveload_ovl.o $(BUILD_DIR)/restore_ovl.o $(BUILD_DIR)/overlay_defs.o $(BUILD_DIR)/overlay_defs.o~ $(BUILD_DIR)/$(ZX_NAME)_RULES.OVL $(BUILD_DIR)/$(ZX_NAME)_BOARD.OVL $(BUILD_DIR)/$(ZX_NAME)_GUI_LOG.OVL $(BUILD_DIR)/$(ZX_NAME)_INPUT_EDIT.OVL $(BUILD_DIR)/$(ZX_NAME)_MQTT_CONNECT.OVL $(BUILD_DIR)/$(ZX_NAME)_MQTT_TX.OVL $(BUILD_DIR)/$(ZX_NAME)_DIRECT.OVL $(BUILD_DIR)/$(ZX_NAME)_MENU_CONFIG.OVL $(BUILD_DIR)/$(ZX_NAME)_MENU_LOGIC.OVL $(BUILD_DIR)/$(ZX_NAME)_FILEUI.OVL $(BUILD_DIR)/$(ZX_NAME)_SETUP.OVL $(BUILD_DIR)/$(ZX_NAME)_SAVELOAD.OVL $(BUILD_DIR)/$(ZX_NAME)_RESTORE.OVL $(BUILD_DIR)/$(ZX_NAME)_ABOUT.OVL $(BUILD_DIR)/$(ZX_NAME).OVL.tmp $(BUILD_DIR)/overlay_atlas_table.changed $(BUILD_DIR)/$(ZX_NAME).OVL.bootstrap 2>/dev/null || true
	rm -f asm/overlay/control/entry_control.o $(BUILD_DIR)/control_ovl.o $(BUILD_DIR)/$(ZX_NAME)_CONTROL.OVL
	rmdir $(RELEASE_DIR) 2>/dev/null || true
endif

clean-client:
ifneq ($(CLIENT_HOST_IS_WINDOWS),)
	$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File tools/clean-generated.ps1 -ClientOnly
else
	rm -rf client/build client/build_manual client/build_verify client/dist
	rm -rf $(RELEASE_DIR)/shatranj-client $(RELEASE_DIR)/shatranj $(RELEASE_DIR)/netchesszx-client
	rm -f main.obj
	rmdir $(RELEASE_DIR) 2>/dev/null || true
endif

# ---------------------------------------------------------------------------
# Sprinter (Estex DSS) target -- additive port scaffolding, see port.md.
# Uses only new paths (asm/sprinter, build/sprinter, release/Sprinter) and
# never touches the rules or artifacts of the other platforms.

.PHONY: exe sprinter-check sprinter-deps-check sprinter-tools-test sprinter-smoke-image \
        sprinter-hw-zip sprinter-layout-check sprinter-z80-test sprinter-resident-test \
        sprinter-host-test \
        sprinter-gates sprinter-section-gate sprinter-crt0-check sprinter-platform-defs-check \
        sprinter-netframe-defs-check sprinter-sccz80-codegen-check \
        sprinter-cold-page-check \
        sprinter-overlay-defs-check sprinter-overlay-control-check \
        sprinter-overlay-rules-check sprinter-overlay-board-check \
        sprinter-overlay-saveload-check sprinter-overlay-restore-check \
        sprinter-overlay-fileui-check sprinter-overlay-net-check \
        sprinter-overlay-input-edit-check \
        sprinter-size-report \
        sprinter-about clean-sprinter

SPRINTER_BUILD_DIR := $(BUILD_DIR)/sprinter
SPRINTER_RELEASE_DIR := $(RELEASE_DIR)/Sprinter
SPRINTER_EXE := $(SPRINTER_RELEASE_DIR)/SHATRANJ.EXE
SPRINTER_SMOKE_IMG := $(SPRINTER_BUILD_DIR)/SHATRANJ-SMOKE.IMG
SPRINTER_HW_ZIP := $(SPRINTER_BUILD_DIR)/SHATRANJ-HW.zip
SPRINTER_ASM_DIR := asm/sprinter
SPRINTER_LOADER_BIN := $(SPRINTER_BUILD_DIR)/preload_loader.bin
# Three independently-assembled blobs, spliced by tools/make_sprinter_resident.py
# into one flat 32 KiB image (plan D1, port.md section 3.10/S5). See that
# tool's docstring for why they can't just be linked together directly.
SPRINTER_TRAMPOLINE_BIN := $(SPRINTER_BUILD_DIR)/trampoline.bin
SPRINTER_PLATFORM_PRIMITIVES_BIN := $(SPRINTER_BUILD_DIR)/platform_primitives.bin
SPRINTER_PLATFORM_PRIMITIVES_SYM := $(SPRINTER_BUILD_DIR)/platform_primitives.sym
SPRINTER_RESIDENT_C_BIN := $(SPRINTER_BUILD_DIR)/resident_c.bin
SPRINTER_RESIDENT_BIN := $(SPRINTER_BUILD_DIR)/resident.bin
SPRINTER_DLLS := extern/esp_net/UNETESP.DLL extern/rtl_net/UNETRTL.DLL

# Fourth splice blob (S7, port.md section 3.7): net_frame.c's own
# independent zcc build, placed at fixed_layout.json's NET_FRAME_C anchor.
# See tools/make_sprinter_resident.py's docstring for how this differs from
# the pre-S7 three-blob shape above.
SPRINTER_NET_CORE_CRT0 := $(SPRINTER_ASM_DIR)/zcc/net_core_crt0.asm
# S8 step 4/5 relief (WIN1 ran out of room twice: 57 bytes free after the
# DRAW/RESET CONTROL FSM, then a 699-byte overrun after takeback):
# game_protocol.c, keepalive_protocol.c and direct_session_protocol.c are
# all portable, mostly leaf parsers/formatters with no globals of their
# own. Moving them here costs nothing at runtime despite being a "window"
# move -- unlike the WIN3 cold page (which needs a save/restore/OUT
# trampoline per call), WIN2 is ALWAYS mapped, so a WIN1 caller reaching a
# WIN2 function via tools/gen_sprinter_netframe_defs.py's defc bridge is a
# plain CALL to a fixed address, identical in cost to calling resident
# code. game_protocol.c is NOT duplicated here and in
# SPRINTER_RESIDENT_C_SRC (unlike keepalive/direct_session_protocol's
# first move in step 4) -- it is large enough (~1.2 KiB) and has few
# enough distinct WIN1 call sites (src/sprinter/main.c,
# src/common/protocol/game_protocol_extra.c) that bridging its dozen-odd
# entry points/string constants once outright was simpler than a second
# shim.
# S8 step 6 relief (WIN1 overran the 16000-byte budget by 1448 bytes after
# RESTORE chunking) moved src/sprinter/transport/unet_link.c here, since it
# only called ng_*/nc_*/game_protocol.c, nothing WIN1-only. S8 step 8a moved
# it BACK to SPRINTER_RESIDENT_C_SRC below: mqtt_min.c (1697 bytes, see that
# paragraph below) fits only in WIN1's much larger budget, and this blob
# builds BEFORE resident_c.bin, so blob code cannot call a WIN1 function by
# its (not yet known) fixed address -- unet_link.c calling into mqtt_min.c
# for the MQTT half of link.h forces the caller to live wherever the callee
# does. Moving unet_link.c costs nothing at the call sites that reach it:
# tools/gen_sprinter_cold_defs.py's COLD_RESIDENT_SYMBOLS and tools/
# gen_sprinter_overlay_defs.py's OVERLAY_RESIDENT_SYMBOLS bridge the same 15
# spectrum_net_* names into WIN1 now instead of tools/gen_sprinter_
# netframe_defs.py's NETFRAME_RESIDENT_SYMBOLS bridging them into this blob;
# the reverse direction (unet_link.c calling this blob's nc_mqtt_* reassembler)
# is what NETFRAME_RESIDENT_SYMBOLS bridges instead now. restore.c/
# saveload.c stay resident, deliberately -- both are thin wrappers whose
# entire body is a call to spectrum_overlay_exec_cached
# (overlay_loader_sprinter.asm), which is linked INTO resident_c.bin and
# has no fixed address this build (built BEFORE resident_c.bin) could
# reference; moving them would need that dispatcher on a fixed address
# too, a bigger change than this step's budget crisis called for.
# session/{ping,direct,outgoing}.c were ALSO tried here (their only WIN1-
# only dependency was unet_link.c's spectrum_link_* surface, now moved),
# but direct.c/outgoing.c pulled in platform/text.c and the whole of
# config/session.c behind them, and the combined total overran this
# blob's own ~4 KiB ceiling (the WIN2 gap between platform_primitives.asm
# and the fixed OVL_SLOT_ADDR is hard-bounded regardless of how far
# NET_FRAME_C.addr is pushed back) -- reverted; those three stay resident.
# mqtt_session_protocol.c (177 bytes when only netchess_mqtt_session_
# parse_u16_token was live, under -DNETCHESSZX_DIRECT_ONLY -- S8 step 8c
# drops that flag for this build, so its parse_host/join/side functions
# compile in too now, growing this file's contribution by roughly the
# ~250 bytes accounted for in that step's own budget note). Bridged the
# same way; tools/gen_sprinter_overlay_defs.py needs NO change despite
# CONTROL overlay also calling netchess_mqtt_session_parse_u16_token --
# that tool reads resident_c.map, and the defc netframe_defs.asm places
# there (PUBLIC _netchess_mqtt_session_parse_u16_token pointing into this
# WIN2 blob) already resolves transitively for it, exactly as it already
# does for netchess_after_prefix/NETCHESS_PROTO_* since step 5's move.
# mqtt_min.c (the MQTT packet codec ZX/Next already link unmodified,
# src/spectrum/transport/net.c's own consumer) is NOT here: measured cost
# under this build's compiler (z88dk +pps/sccz80, not ZX's SDCC/IY -- the
# two are not comparable) is 1697 bytes whole-file-linked, against this
# blob's ~4.5 KiB ceiling with only ~700 bytes free after the nc_mqtt_*
# reassembler below already used its share -- it would not fit here even
# alone. S8 step 8a links it into SPRINTER_RESIDENT_C_SRC below instead,
# alongside unet_link.c (see that move's own comment above): WIN1's budget
# is the only one of the three pools large enough, and unet_link.c's new
# MQTT half of link.h is the first real caller (net_frame.c's nc_mqtt_* was
# always only a reassembler, never a codec). tests/sprinter/host/
# test_net_frame.c already links mqtt_min.c on the host build below (zero
# byte cost there) for a real round-trip proof of the reassembler feeding
# this exact codec, unaffected by which target build links it.
SPRINTER_NET_FRAME_C_SRC := src/sprinter/transport/net_frame.c \
                           src/common/protocol/game_protocol.c \
                           src/common/protocol/mqtt_session_protocol.c \
                           src/spectrum/transport/keepalive_protocol.c \
                           src/common/protocol/direct_session_protocol.c
SPRINTER_NET_FRAME_C_BIN := $(SPRINTER_BUILD_DIR)/net_frame_c.bin
SPRINTER_NET_FRAME_C_MAP := $(SPRINTER_BUILD_DIR)/net_frame_c.map

# WIN3 cold-code page: everything that is NOT in the hot render cycle,
# linked at #C000 with its own crt0 and shipped as a whole asset page
# rather than as part of the WIN1 resident C image. Not a splice blob like
# net_frame_c above: it is mapped into WIN3 on demand by the stubs
# gen_sprinter_cold_thunks.py generates, so it never occupies resident
# address space at all. See render_core.asm's own header for why WIN3 is
# safe for rendering code, and cold_page_crt0.asm's for the entry table.
#
# S7 step 4 seeded it with the painters (render_core*.asm). S7 step 5 made
# the boundary bidirectional and moved whole C modules in: gui.c (4846
# bytes of clocks/timers/notices/menu/panel state, one thunk per frame) and
# the network join UI. The budget rule is heat, not size -- per-frame pixel
# work stays out (render_shim.asm), everything reached a handful of times
# per second or per user action belongs here.
SPRINTER_COLD_PAGE_CRT0 := $(SPRINTER_ASM_DIR)/zcc/cold_page_crt0.asm
# S8 relief pass: src/sprinter/session_sprinter.c is the DIRECT-session/
# board-interaction/menu-action driver that used to be main.c's own body
# (board_select_or_move through handle_menu_action) -- moved here verbatim
# once WIN1 ran out of room for step 8's MQTT work, matching gui.c's own
# earlier move onto this same page. See that file's own header for the
# full rationale and tools/gen_sprinter_cold_defs.py's COLD_RESIDENT_
# SYMBOLS / tools/gen_sprinter_cold_thunks.py's COLD_THUNK_SYMBOLS for the
# two halves of the bridge it needed.
SPRINTER_COLD_PAGE_SRC := $(SPRINTER_ASM_DIR)/zcc/render_core.asm \
                          $(SPRINTER_ASM_DIR)/zcc/render_core_cold.asm \
                          src/spectrum/ui/gui.c \
                          src/sprinter/session_sprinter.c
# src/sprinter/net_ui_sprinter.c moved OFF this page in S8 step 8b, onto its
# own WIN3 page as the NET overlay (SPRINTER_OVL_NET_BIN below) -- the cold
# page had only 43 bytes free (measured 2026-08-14 recon) once step 8a's
# unet_link.c/mqtt_min.c moves were accounted for, nowhere near this file's
# 1431 bytes. See that overlay's own Makefile rule and net_ui_sprinter.c's
# own header for the full rationale.
SPRINTER_COLD_PAGE_ORG := 0xC000
SPRINTER_COLD_IMAGE_BIN := $(SPRINTER_BUILD_DIR)/cold_page_image.bin
SPRINTER_COLD_IMAGE_MAP := $(SPRINTER_BUILD_DIR)/cold_page_image.map
SPRINTER_COLD_WIN3_PAGE := $(SPRINTER_BUILD_DIR)/cold_win3_page.bin

SPRINTER_LAYOUT_JSON := src/sprinter/fixed_layout.json
SPRINTER_GENERATED_DIR := $(SPRINTER_BUILD_DIR)/generated
SPRINTER_PLATFORM_DEFS_ASM := $(SPRINTER_GENERATED_DIR)/platform_defs.asm
SPRINTER_LAYOUT_INC := $(SPRINTER_GENERATED_DIR)/fixed_layout.inc
SPRINTER_LAYOUT_H := $(SPRINTER_GENERATED_DIR)/fixed_layout.h
SJASMPLUS_INCLUDES := -I $(SPRINTER_ASM_DIR) -I $(SPRINTER_GENERATED_DIR) \
                       -I extern/libman/libman -I extern/esp_net/src/include

SPRINTER_RENDER_LAYOUT_JSON := src/sprinter/render_layout.json
SPRINTER_RENDER_LAYOUT_INC := $(SPRINTER_GENERATED_DIR)/render_layout.inc
SPRINTER_RENDER_LAYOUT_H := $(SPRINTER_GENERATED_DIR)/render_layout.h
SPRINTER_ASSETS_PAGE := $(SPRINTER_BUILD_DIR)/assets_page.bin

# Forward-declared here (path only, not the build rule -- that comes later,
# after resident_c.bin/overlay_defs_sprinter.asm) so the assets-page rule
# below can list it as a prerequisite: make expands prerequisite lists at
# parse time, so a := reference used before its own definition would
# silently resolve empty (the same class of bug SPRINTER_GENERATED_DIR hit
# earlier in this file).
SPRINTER_OVL_CONTROL_BIN := $(SPRINTER_BUILD_DIR)/overlay_control_sprinter.bin
SPRINTER_OVL_RULES_BIN := $(SPRINTER_BUILD_DIR)/overlay_rules_sprinter.bin
SPRINTER_OVL_BOARD_BIN := $(SPRINTER_BUILD_DIR)/overlay_board_sprinter.bin
SPRINTER_OVL_SAVELOAD_BIN := $(SPRINTER_BUILD_DIR)/overlay_saveload_sprinter.bin
SPRINTER_OVL_RESTORE_BIN := $(SPRINTER_BUILD_DIR)/overlay_restore_sprinter.bin
SPRINTER_OVL_FILEUI_BIN := $(SPRINTER_BUILD_DIR)/overlay_fileui_sprinter.bin
SPRINTER_OVL_NET_BIN := $(SPRINTER_BUILD_DIR)/overlay_net_sprinter.bin
SPRINTER_OVL_INPUT_EDIT_BIN := $(SPRINTER_BUILD_DIR)/overlay_input_edit_sprinter.bin
SPRINTER_OVL_ABOUT_BIN := $(SPRINTER_BUILD_DIR)/overlay_about_sprinter.bin

# About screen artwork (S9 About pass): the committed, already-palettised
# PNG plus everything tools/build_sprinter_about.py derives from it. The
# four image pages become asset pages 7-10; the palette is emitted twice,
# once as raw bytes (unused by the build, kept for inspection) and once as a
# z80asm source include the ABOUT overlay assembles in.
SPRINTER_ABOUT_PNG := assets/sprinter/about640.png
SPRINTER_ABOUT_PAL := $(SPRINTER_BUILD_DIR)/about_pal.bin
SPRINTER_ABOUT_PAL_INC := $(SPRINTER_GENERATED_DIR)/about_palette.inc
SPRINTER_ABOUT_MANIFEST := $(SPRINTER_BUILD_DIR)/about_manifest.json
SPRINTER_ABOUT_PAGE_PREFIX := $(SPRINTER_BUILD_DIR)/about_page
SPRINTER_ABOUT_PAGE0 := $(SPRINTER_ABOUT_PAGE_PREFIX)0.bin
SPRINTER_ABOUT_PAGE1 := $(SPRINTER_ABOUT_PAGE_PREFIX)1.bin
SPRINTER_ABOUT_PAGE2 := $(SPRINTER_ABOUT_PAGE_PREFIX)2.bin
SPRINTER_ABOUT_PAGE3 := $(SPRINTER_ABOUT_PAGE_PREFIX)3.bin
SPRINTER_ABOUT_DEPS := tools/build_sprinter_about.py $(SPRINTER_ABOUT_PNG)
SPRINTER_ABOUT_BUILD = $(PYTHON) tools/build_sprinter_about.py \
		--input $(SPRINTER_ABOUT_PNG) --palette-out $(SPRINTER_ABOUT_PAL) \
		--palette-inc-out $(SPRINTER_ABOUT_PAL_INC) \
		--pages-out-prefix $(SPRINTER_ABOUT_PAGE_PREFIX) \
		--manifest-out $(SPRINTER_ABOUT_MANIFEST)

SPRINTER_PALETTE_JSON := assets/sprinter/palette.json
SPRINTER_PALETTE_INC := $(SPRINTER_GENERATED_DIR)/palette_base.inc
SPRINTER_THEME_BIN := $(SPRINTER_BUILD_DIR)/theme_table.bin

SPRINTER_SELECTED_SETS_JSON := assets/lichess/selected_next_sets.json
SPRINTER_PIECES_ROOT := assets/sprinter/pieces
SPRINTER_PIECE_PAGE1 := $(SPRINTER_BUILD_DIR)/piece_page1.bin
SPRINTER_PIECE_PAGE2 := $(SPRINTER_BUILD_DIR)/piece_page2.bin
SPRINTER_PIECE_TILES_MANIFEST := $(SPRINTER_BUILD_DIR)/piece_tiles_manifest.json
SPRINTER_PIECE_PNGS := $(wildcard $(SPRINTER_PIECES_ROOT)/*/*.png)
# $(wildcard) is expanded once, at parse time: DELETING a piece PNG would
# simply drop it from the list, leaving the packed pages stale instead of
# failing loudly. The containing directories are prerequisites too, and a
# directory's mtime moves whenever a file in it is added or removed -- so a
# deletion still forces the packer to re-run (and then reject the missing
# input by name).
SPRINTER_PIECE_DIRS := $(SPRINTER_PIECES_ROOT) $(sort $(dir $(SPRINTER_PIECE_PNGS)))

SPRINTER_LOGO_PNG := assets/sprinter/logo_sprinter.png
SPRINTER_MARKER_DOT_PNG := assets/sprinter/markers/dot.png
SPRINTER_MARKER_RING_PNG := assets/sprinter/markers/ring.png
SPRINTER_FRAME_CURSOR_PNG := assets/sprinter/markers/cursor.png
SPRINTER_FRAME_SELECT_PNG := assets/sprinter/markers/select.png
SPRINTER_UI_ASSETS_BIN := $(SPRINTER_BUILD_DIR)/ui_assets.bin
SPRINTER_UI_ASSETS_MANIFEST := $(SPRINTER_BUILD_DIR)/ui_assets_manifest.json

SPRINTER_VERSION_INC := $(SPRINTER_GENERATED_DIR)/sprinter_version.inc

sprinter-deps-check: tools/check_sprinter_deps.py
	$(PYTHON) tools/check_sprinter_deps.py

sprinter-tools-test: tests/tools/test_sprinter_exe.py tools/make_sprinter_exe.py \
                     tests/tools/test_sprinter_assets_page.py tools/make_sprinter_assets_page.py \
                     tests/tools/test_sprinter_overlay_page.py tools/make_sprinter_overlay_page.py \
                     tests/tools/test_sprinter_cold_page.py tools/make_sprinter_cold_page.py \
                     tools/gen_sprinter_cold_thunks.py tools/gen_sprinter_cold_defs.py \
                     tests/tools/test_rasterize_sprinter_pieces.py tools/rasterize_sprinter_pieces.py \
                     tests/tools/test_sprinter_piece_tiles.py tools/build_sprinter_piece_tiles.py \
                     tests/tools/test_prepare_sprinter_logo.py tools/prepare_sprinter_logo.py \
                     tests/tools/test_make_sprinter_markers.py tools/make_sprinter_markers.py \
                     tests/tools/test_sprinter_ui_assets.py tools/build_sprinter_ui_assets.py \
                     tests/tools/test_sprinter_about.py tools/build_sprinter_about.py \
                     tests/tools/test_sprinter_version.py tools/gen_sprinter_version.py \
                     tools/sprinter_echo_server.py
	$(PYTHON) tests/tools/test_sprinter_exe.py
	$(PYTHON) tests/tools/test_sprinter_assets_page.py
	$(PYTHON) tests/tools/test_sprinter_overlay_page.py
	$(PYTHON) tests/tools/test_sprinter_cold_page.py
	$(PYTHON) tests/tools/test_rasterize_sprinter_pieces.py
	$(PYTHON) tests/tools/test_sprinter_piece_tiles.py
	$(PYTHON) tests/tools/test_prepare_sprinter_logo.py
	$(PYTHON) tests/tools/test_make_sprinter_markers.py
	$(PYTHON) tests/tools/test_sprinter_ui_assets.py
	$(PYTHON) tests/tools/test_sprinter_about.py
	$(PYTHON) tests/tools/test_sprinter_version.py
	$(PYTHON) tools/sprinter_echo_server.py --self-test

sprinter-layout-check: tools/gen_sprinter_layout.py tests/tools/test_sprinter_layout.py $(SPRINTER_LAYOUT_JSON) \
                       tools/gen_sprinter_render_layout.py tests/tools/test_sprinter_render_layout.py \
                       $(SPRINTER_RENDER_LAYOUT_JSON) \
                       tools/gen_sprinter_palette.py tests/tools/test_sprinter_palette.py \
                       $(SPRINTER_PALETTE_JSON)
	$(PYTHON) tools/gen_sprinter_layout.py --self-test
	$(PYTHON) tests/tools/test_sprinter_layout.py
	$(PYTHON) tools/gen_sprinter_render_layout.py --self-test
	$(PYTHON) tests/tools/test_sprinter_render_layout.py
	$(PYTHON) tools/gen_sprinter_palette.py --self-test
	$(PYTHON) tests/tools/test_sprinter_palette.py
	@printf "[OK] sprinter-layout-check: fixed layout + render layout + palette valid\n"

sprinter-gates: tools/check_sprinter_accel.py tools/check_sprinter_win0.py
	$(PYTHON) tools/check_sprinter_accel.py --self-test
	$(PYTHON) tools/check_sprinter_accel.py --root .
	$(PYTHON) tools/check_sprinter_win0.py --self-test
	$(PYTHON) tools/check_sprinter_win0.py --root .
	@printf "[OK] sprinter-gates: R1/R3 static policy checks green\n"

sprinter-platform-defs-check: tools/gen_sprinter_platform_defs.py
	$(PYTHON) tools/gen_sprinter_platform_defs.py --self-test

sprinter-section-gate: tools/check_sprinter_net_sections.py $(SPRINTER_PLATFORM_PRIMITIVES_SYM)
	$(PYTHON) tools/check_sprinter_net_sections.py --self-test
	$(PYTHON) tools/check_sprinter_net_sections.py --sym $(SPRINTER_PLATFORM_PRIMITIVES_SYM)
	@printf "[OK] sprinter-section-gate: WIN1/WIN2 net-mechanics split holds\n"

# --- z88dk bridge (plan D1, port.md section 3.10/S5) ------------------------
# asm/sprinter/zcc/resident_crt0.asm replaces z88dk's stock pps_crt0.asm
# (which bakes a DSS EXE header + PSP/argv handling into the image -- wrong
# shape for a page streamed in by preload_loader.asm and JP'd into directly
# by platform_core's trampoline). crt0_probe_main.c/crt0_probe_defs.asm are
# a permanent regression fixture (dummy_overlay.asm's role, not real
# production code): proves the crt0 produces a headerless image with _main
# reachable and an externally-resolved fixed-address symbol linked, the
# same shape tools/gen_sprinter_platform_defs.py will produce for real
# platform_core primitives. CRT_ORG_CODE here is an arbitrary placeholder
# (the real C-image base is fixed once substep 1's size checkpoint lands);
# this target is not part of the resident image and never linked into it.
SPRINTER_ZCC_DIR := $(SPRINTER_ASM_DIR)/zcc
SPRINTER_CRT0_ASM := $(SPRINTER_ZCC_DIR)/resident_crt0.asm
SPRINTER_CRT0_PROBE_BIN := $(SPRINTER_BUILD_DIR)/crt0_probe.bin
SPRINTER_CRT0_PROBE_MAP := $(SPRINTER_BUILD_DIR)/crt0_probe.map
SPRINTER_CRT0_PROBE_ORG := 0x4200

$(SPRINTER_CRT0_PROBE_BIN): $(SPRINTER_CRT0_ASM) $(SPRINTER_ZCC_DIR)/crt0_probe_main.c \
                            $(SPRINTER_ZCC_DIR)/crt0_probe_defs.asm | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps -clib=default -SO3 -pragma-define:CRT_ORG_CODE=$(SPRINTER_CRT0_PROBE_ORG) \
		-crt0=$(patsubst %.asm,%,$(SPRINTER_CRT0_ASM)) -m \
		-o $(SPRINTER_CRT0_PROBE_BIN) \
		$(SPRINTER_ZCC_DIR)/crt0_probe_main.c $(SPRINTER_ZCC_DIR)/crt0_probe_defs.asm

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment
# above (macOS ships GNU make 3.81, no grouped-target support).
$(SPRINTER_CRT0_PROBE_MAP): $(SPRINTER_CRT0_ASM) $(SPRINTER_ZCC_DIR)/crt0_probe_main.c \
                            $(SPRINTER_ZCC_DIR)/crt0_probe_defs.asm | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps -clib=default -SO3 -pragma-define:CRT_ORG_CODE=$(SPRINTER_CRT0_PROBE_ORG) \
		-crt0=$(patsubst %.asm,%,$(SPRINTER_CRT0_ASM)) -m \
		-o $(SPRINTER_CRT0_PROBE_BIN) \
		$(SPRINTER_ZCC_DIR)/crt0_probe_main.c $(SPRINTER_ZCC_DIR)/crt0_probe_defs.asm

sprinter-crt0-check: tests/tools/test_sprinter_crt0.py $(SPRINTER_CRT0_PROBE_BIN) $(SPRINTER_CRT0_PROBE_MAP)
	$(PYTHON) tests/tools/test_sprinter_crt0.py
	@printf "[OK] sprinter-crt0-check: headerless resident_crt0.asm entry verified\n"

$(SPRINTER_BUILD_DIR):
	mkdir -p $(SPRINTER_BUILD_DIR)

$(SPRINTER_GENERATED_DIR):
	mkdir -p $(SPRINTER_GENERATED_DIR)

$(SPRINTER_LAYOUT_INC): tools/gen_sprinter_layout.py $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_layout.py --layout $(SPRINTER_LAYOUT_JSON) \
		--inc-out $(SPRINTER_LAYOUT_INC) --h-out $(SPRINTER_LAYOUT_H)

# Mirror rule, not a grouped "&:" target: the recipe writes both files, but
# grouped targets need GNU make 4.3+ and macOS ships 3.81. Safe without
# parallel-build races because of the global .NOTPARALLEL.
$(SPRINTER_LAYOUT_H): tools/gen_sprinter_layout.py $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_layout.py --layout $(SPRINTER_LAYOUT_JSON) \
		--inc-out $(SPRINTER_LAYOUT_INC) --h-out $(SPRINTER_LAYOUT_H)

$(SPRINTER_RENDER_LAYOUT_INC): tools/gen_sprinter_render_layout.py $(SPRINTER_RENDER_LAYOUT_JSON) | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_render_layout.py --layout $(SPRINTER_RENDER_LAYOUT_JSON) \
		--inc-out $(SPRINTER_RENDER_LAYOUT_INC) --h-out $(SPRINTER_RENDER_LAYOUT_H)

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment above.
$(SPRINTER_RENDER_LAYOUT_H): tools/gen_sprinter_render_layout.py $(SPRINTER_RENDER_LAYOUT_JSON) | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_render_layout.py --layout $(SPRINTER_RENDER_LAYOUT_JSON) \
		--inc-out $(SPRINTER_RENDER_LAYOUT_INC) --h-out $(SPRINTER_RENDER_LAYOUT_H)

$(SPRINTER_PALETTE_INC): tools/gen_sprinter_palette.py $(SPRINTER_PALETTE_JSON) | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_palette.py --palette $(SPRINTER_PALETTE_JSON) \
		--inc-out $(SPRINTER_PALETTE_INC) --theme-bin-out $(SPRINTER_THEME_BIN)

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment above.
$(SPRINTER_THEME_BIN): tools/gen_sprinter_palette.py $(SPRINTER_PALETTE_JSON) | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_palette.py --palette $(SPRINTER_PALETTE_JSON) \
		--inc-out $(SPRINTER_PALETTE_INC) --theme-bin-out $(SPRINTER_THEME_BIN)

# VERSION is the single source of truth (CLAUDE.md rule 5: no version
# literals in code); scene_s4.asm's banner reads sprinter_banner_msg
# instead of embedding a string of its own. The template lives in the
# generator, not here: tools/run_sprinter_z80_tests.sh needs the same file
# in its own private generated dir, and two inline copies would drift.
$(SPRINTER_VERSION_INC): tools/gen_sprinter_version.py VERSION | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_version.py --version-file VERSION \
		--inc-out $(SPRINTER_VERSION_INC)

# Same string, z88dk-z80asm dialect, for the ABOUT overlay's caption (the
# overlays under asm/sprinter/zcc are not assembled by sjasmplus).
SPRINTER_VERSION_INC_Z80ASM := $(SPRINTER_GENERATED_DIR)/sprinter_version_z80asm.asm

$(SPRINTER_VERSION_INC_Z80ASM): tools/gen_sprinter_version.py VERSION | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_version.py --version-file VERSION \
		--mode z80asm --inc-out $(SPRINTER_VERSION_INC_Z80ASM)

$(SPRINTER_LOADER_BIN): $(SPRINTER_ASM_DIR)/preload_loader.asm $(SPRINTER_ASM_DIR)/dss.inc \
                        $(SPRINTER_ASM_DIR)/manifest.inc $(SPRINTER_ASM_DIR)/hdr.inc \
                        $(SPRINTER_LAYOUT_INC) | $(SPRINTER_BUILD_DIR)
	$(SJASMPLUS) --nologo --fullpath $(SJASMPLUS_INCLUDES) \
		--raw=$(SPRINTER_LOADER_BIN) $(SPRINTER_ASM_DIR)/preload_loader.asm

SPRINTER_UI_ASSETS_DEPS := tools/build_sprinter_ui_assets.py $(SPRINTER_PALETTE_JSON) \
                           $(SPRINTER_LOGO_PNG) $(SPRINTER_MARKER_DOT_PNG) $(SPRINTER_MARKER_RING_PNG) \
                           $(SPRINTER_FRAME_CURSOR_PNG) $(SPRINTER_FRAME_SELECT_PNG)

$(SPRINTER_UI_ASSETS_BIN): $(SPRINTER_UI_ASSETS_DEPS) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/build_sprinter_ui_assets.py \
		--logo $(SPRINTER_LOGO_PNG) --marker-dot $(SPRINTER_MARKER_DOT_PNG) \
		--marker-ring $(SPRINTER_MARKER_RING_PNG) \
		--frame-cursor $(SPRINTER_FRAME_CURSOR_PNG) \
		--frame-select $(SPRINTER_FRAME_SELECT_PNG) --palette $(SPRINTER_PALETTE_JSON) \
		--output $(SPRINTER_UI_ASSETS_BIN) --manifest-out $(SPRINTER_UI_ASSETS_MANIFEST)

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment above.
$(SPRINTER_UI_ASSETS_MANIFEST): $(SPRINTER_UI_ASSETS_DEPS) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/build_sprinter_ui_assets.py \
		--logo $(SPRINTER_LOGO_PNG) --marker-dot $(SPRINTER_MARKER_DOT_PNG) \
		--marker-ring $(SPRINTER_MARKER_RING_PNG) \
		--frame-cursor $(SPRINTER_FRAME_CURSOR_PNG) \
		--frame-select $(SPRINTER_FRAME_SELECT_PNG) --palette $(SPRINTER_PALETTE_JSON) \
		--output $(SPRINTER_UI_ASSETS_BIN) --manifest-out $(SPRINTER_UI_ASSETS_MANIFEST)

$(SPRINTER_ASSETS_PAGE): tools/make_sprinter_assets_page.py extern/sprinter-libs/afnt640/font.bin \
                         $(SPRINTER_OVL_CONTROL_BIN) $(SPRINTER_THEME_BIN) $(SPRINTER_UI_ASSETS_BIN) \
                         | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/make_sprinter_assets_page.py \
		--font-bin extern/sprinter-libs/afnt640/font.bin \
		--overlay-bin $(SPRINTER_OVL_CONTROL_BIN) \
		--theme-bin $(SPRINTER_THEME_BIN) \
		--ui-bin $(SPRINTER_UI_ASSETS_BIN) \
		--output $(SPRINTER_ASSETS_PAGE)

SPRINTER_PIECE_TILES_DEPS := tools/build_sprinter_piece_tiles.py $(SPRINTER_PALETTE_JSON) \
                             $(SPRINTER_SELECTED_SETS_JSON) $(SPRINTER_PIECE_PNGS) \
                             $(SPRINTER_PIECE_DIRS)

$(SPRINTER_PIECE_PAGE1): $(SPRINTER_PIECE_TILES_DEPS) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/build_sprinter_piece_tiles.py \
		--pieces-root $(SPRINTER_PIECES_ROOT) --sets-json $(SPRINTER_SELECTED_SETS_JSON) \
		--palette $(SPRINTER_PALETTE_JSON) \
		--page1-out $(SPRINTER_PIECE_PAGE1) --page2-out $(SPRINTER_PIECE_PAGE2) \
		--manifest-out $(SPRINTER_PIECE_TILES_MANIFEST) --preview-dir $(SPRINTER_BUILD_DIR)/preview

# Mirror rules, not a grouped "&:" target -- see the fixed_layout.h comment
# above (macOS ships GNU make 3.81, no grouped-target support).
$(SPRINTER_PIECE_PAGE2): $(SPRINTER_PIECE_TILES_DEPS) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/build_sprinter_piece_tiles.py \
		--pieces-root $(SPRINTER_PIECES_ROOT) --sets-json $(SPRINTER_SELECTED_SETS_JSON) \
		--palette $(SPRINTER_PALETTE_JSON) \
		--page1-out $(SPRINTER_PIECE_PAGE1) --page2-out $(SPRINTER_PIECE_PAGE2) \
		--manifest-out $(SPRINTER_PIECE_TILES_MANIFEST) --preview-dir $(SPRINTER_BUILD_DIR)/preview

$(SPRINTER_PIECE_TILES_MANIFEST): $(SPRINTER_PIECE_TILES_DEPS) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/build_sprinter_piece_tiles.py \
		--pieces-root $(SPRINTER_PIECES_ROOT) --sets-json $(SPRINTER_SELECTED_SETS_JSON) \
		--palette $(SPRINTER_PALETTE_JSON) \
		--page1-out $(SPRINTER_PIECE_PAGE1) --page2-out $(SPRINTER_PIECE_PAGE2) \
		--manifest-out $(SPRINTER_PIECE_TILES_MANIFEST) --preview-dir $(SPRINTER_BUILD_DIR)/preview

# About artwork. Mirror rules again, one per output, for the same GNU make
# 3.81 reason the piece-tile rules above spell out (no grouped targets).
$(SPRINTER_ABOUT_PAGE0): $(SPRINTER_ABOUT_DEPS) | $(SPRINTER_BUILD_DIR) $(SPRINTER_GENERATED_DIR)
	$(SPRINTER_ABOUT_BUILD)

$(SPRINTER_ABOUT_PAGE1): $(SPRINTER_ABOUT_DEPS) | $(SPRINTER_BUILD_DIR) $(SPRINTER_GENERATED_DIR)
	$(SPRINTER_ABOUT_BUILD)

$(SPRINTER_ABOUT_PAGE2): $(SPRINTER_ABOUT_DEPS) | $(SPRINTER_BUILD_DIR) $(SPRINTER_GENERATED_DIR)
	$(SPRINTER_ABOUT_BUILD)

$(SPRINTER_ABOUT_PAGE3): $(SPRINTER_ABOUT_DEPS) | $(SPRINTER_BUILD_DIR) $(SPRINTER_GENERATED_DIR)
	$(SPRINTER_ABOUT_BUILD)

$(SPRINTER_ABOUT_PAL): $(SPRINTER_ABOUT_DEPS) | $(SPRINTER_BUILD_DIR) $(SPRINTER_GENERATED_DIR)
	$(SPRINTER_ABOUT_BUILD)

$(SPRINTER_ABOUT_PAL_INC): $(SPRINTER_ABOUT_DEPS) | $(SPRINTER_BUILD_DIR) $(SPRINTER_GENERATED_DIR)
	$(SPRINTER_ABOUT_BUILD)

# --- z88dk bridge: trampoline + platform primitives + C image + splice ----
# (plan D1, port.md section 3.10/S5). Three independent builds, agreeing
# only on src/sprinter/fixed_layout.json's fixed anchors; tools/
# make_sprinter_resident.py is where that agreement is actually checked.

SPRINTER_TRAMPOLINE_DEPS := $(SPRINTER_ASM_DIR)/trampoline.asm $(SPRINTER_ASM_DIR)/dss.inc \
                            $(SPRINTER_ASM_DIR)/hdr.inc $(SPRINTER_LAYOUT_INC)

$(SPRINTER_TRAMPOLINE_BIN): $(SPRINTER_TRAMPOLINE_DEPS) | $(SPRINTER_BUILD_DIR)
	$(SJASMPLUS) --nologo --fullpath $(SJASMPLUS_INCLUDES) \
		--raw=$(SPRINTER_TRAMPOLINE_BIN) $(SPRINTER_ASM_DIR)/trampoline.asm

SPRINTER_PLATFORM_PRIMITIVES_DEPS := $(SPRINTER_ASM_DIR)/platform_primitives.asm \
                          $(SPRINTER_ASM_DIR)/im2_s1.asm $(SPRINTER_ASM_DIR)/video.asm \
                          $(SPRINTER_ASM_DIR)/buffers.asm \
                          $(SPRINTER_ASM_DIR)/win0.inc $(SPRINTER_ASM_DIR)/accel.inc \
                          $(SPRINTER_ASM_DIR)/dss.inc \
                          $(SPRINTER_ASM_DIR)/gfx_core.asm $(SPRINTER_ASM_DIR)/text640.asm \
                          $(SPRINTER_ASM_DIR)/net_gate.asm $(SPRINTER_ASM_DIR)/dss_fileio.asm \
                          $(SPRINTER_ASM_DIR)/hdr.inc $(SPRINTER_LAYOUT_INC) \
                          $(SPRINTER_PALETTE_INC) $(SPRINTER_RENDER_LAYOUT_INC)

$(SPRINTER_PLATFORM_PRIMITIVES_BIN): $(SPRINTER_PLATFORM_PRIMITIVES_DEPS) | $(SPRINTER_BUILD_DIR)
	$(SJASMPLUS) --nologo --fullpath $(SJASMPLUS_INCLUDES) \
		--raw=$(SPRINTER_PLATFORM_PRIMITIVES_BIN) --sym=$(SPRINTER_PLATFORM_PRIMITIVES_SYM) \
		$(SPRINTER_ASM_DIR)/platform_primitives.asm

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment
# above (macOS ships GNU make 3.81, no grouped-target support).
$(SPRINTER_PLATFORM_PRIMITIVES_SYM): $(SPRINTER_PLATFORM_PRIMITIVES_DEPS) | $(SPRINTER_BUILD_DIR)
	$(SJASMPLUS) --nologo --fullpath $(SJASMPLUS_INCLUDES) \
		--raw=$(SPRINTER_PLATFORM_PRIMITIVES_BIN) --sym=$(SPRINTER_PLATFORM_PRIMITIVES_SYM) \
		$(SPRINTER_ASM_DIR)/platform_primitives.asm

$(SPRINTER_PLATFORM_DEFS_ASM): tools/gen_sprinter_platform_defs.py $(SPRINTER_PLATFORM_PRIMITIVES_SYM) \
                               | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_platform_defs.py --sym $(SPRINTER_PLATFORM_PRIMITIVES_SYM) \
		--out $(SPRINTER_PLATFORM_DEFS_ASM)

# net_frame.c (S7, port.md section 3.7): the fourth splice blob, built
# independently of the resident C image with its own crt0 (net_core_crt0.
# asm) at a fixed ORG (fixed_layout.json's NET_FRAME_C_ADDR) -- same
# three-independent-builds-agreeing-only-on-fixed_layout.json shape as
# trampoline/platform_primitives/resident_c above. Also builds unmodified
# under gcc for tests/sprinter/host/test_net_frame.c (S7 step 2); this
# rule is the zcc/target side only.
#
# Step 3's nc_pump() (compiled in only under -DNETCHESSZX_SPRINTER) calls
# net_gate.asm's ng_c_recv_poll/ng_buf_rx/ng_v_call_* -- real WIN2
# addresses this independent link session has no other way to see, so
# SPRINTER_PLATFORM_DEFS_ASM is linked in here too (defc's only, zero
# bytes contributed), the same generated bridge resident_c.bin already
# uses for the same call surface.
SPRINTER_NET_FRAME_C_DEPS := $(SPRINTER_NET_FRAME_C_SRC) $(SPRINTER_NET_CORE_CRT0) \
                             $(SPRINTER_PLATFORM_DEFS_ASM) $(SPRINTER_LAYOUT_INC)

$(SPRINTER_NET_FRAME_C_BIN): $(SPRINTER_NET_FRAME_C_DEPS) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps -clib=default -SO3 -Isrc -I$(SPRINTER_ASM_DIR)/zcc -I$(SPRINTER_GENERATED_DIR) \
		-DNETCHESSZX_SPRINTER -DNETCHESSZX_FIXED_LOW_RAM \
		-pragma-define:CRT_ORG_CODE=$$($(PYTHON) tools/gen_sprinter_layout.py \
			--layout $(SPRINTER_LAYOUT_JSON) --print-symbol NET_FRAME_C_ADDR) \
		-crt0=$(patsubst %.asm,%,$(SPRINTER_NET_CORE_CRT0)) -m \
		-o $(SPRINTER_NET_FRAME_C_BIN) \
		$(SPRINTER_NET_FRAME_C_SRC) $(SPRINTER_PLATFORM_DEFS_ASM)

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment
# above (macOS ships GNU make 3.81, no grouped-target support).
$(SPRINTER_NET_FRAME_C_MAP): $(SPRINTER_NET_FRAME_C_BIN)

SPRINTER_NETFRAME_DEFS_ASM := $(SPRINTER_GENERATED_DIR)/netframe_defs.asm

$(SPRINTER_NETFRAME_DEFS_ASM): tools/gen_sprinter_netframe_defs.py $(SPRINTER_NET_FRAME_C_MAP) \
                               | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_netframe_defs.py --map $(SPRINTER_NET_FRAME_C_MAP) \
		--out $(SPRINTER_NETFRAME_DEFS_ASM)

sprinter-netframe-defs-check: tools/gen_sprinter_netframe_defs.py
	$(PYTHON) tools/gen_sprinter_netframe_defs.py --self-test

# sccz80 emits wrong code for a conditional expression whose condition
# contains && or || -- the result is computed into HL and then tested in the
# carry flag, so the false branch always wins. Silent at every other gate;
# it cost three MAME rounds in S8 step 8 before it was found (a successful
# MQTT CONNECT reported as a failed send). This recompiles every Sprinter C
# source with the real build's flags and rejects the emitted shape.
# ZX/Next are SDCC and unaffected -- this gate is Sprinter-only by design.
.PHONY: sprinter-sccz80-codegen-check
sprinter-sccz80-codegen-check: tools/check_sccz80_codegen.py $(SPRINTER_LAYOUT_H) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(PYTHON) tools/check_sccz80_codegen.py --self-test
	ZCC=$(ZCC) $(PYTHON) tools/check_sccz80_codegen.py

# WIN3 cold-code page. Same "independent zcc build at a fixed ORG, padded
# to a whole 16 KiB asset page" shape as before, but since S7 step 5 the
# dependency arrow points the OTHER way: this page is built AFTER
# resident_c.bin, not before it.
#
# What made that possible: the WIN1 thunks no longer read this build's
# .map. They call $C000+3*i into the generated entry table below, which the
# crt0 pins to the top of the image, so both halves come from one ordered
# allowlist in tools/gen_sprinter_cold_thunks.py and neither build has to
# see the other's output. That freed the order, and the freed order is what
# lets cold-page code CALL BACK into the resident through
# tools/gen_sprinter_cold_defs.py's defc bridge -- without which the page
# could only ever hold leaf code (gui.c calls text.c, the session config
# and the frame/key shims, all resident).
SPRINTER_COLD_THUNKS_ASM := $(SPRINTER_GENERATED_DIR)/cold_thunks.asm
SPRINTER_COLD_ENTRY_TABLE := $(SPRINTER_GENERATED_DIR)/cold_entry_table.inc
SPRINTER_COLD_DEFS_ASM := $(SPRINTER_GENERATED_DIR)/cold_defs.asm

# Both halves of the boundary, from the same allowlist and neither from a
# .map -- that is the whole point (see above).
$(SPRINTER_COLD_THUNKS_ASM): tools/gen_sprinter_cold_thunks.py \
                             | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_cold_thunks.py --mode thunks \
		--out $(SPRINTER_COLD_THUNKS_ASM)

$(SPRINTER_COLD_ENTRY_TABLE): tools/gen_sprinter_cold_thunks.py \
                              | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_cold_thunks.py --mode entry-table \
		--out $(SPRINTER_COLD_ENTRY_TABLE)

# Depends on the resident .bin, NOT the .map. The .map is written as a side
# effect of the resident link and its own rule carries no recipe, and with
# that shape GNU make 3.81 decided this target was up to date while the map
# under it had moved -- so the cold page kept calling WIN1 addresses from a
# previous layout. That is not a theoretical race: on 2026-08-15 it shipped
# a build in which 42 of these 78 bridge symbols pointed at the wrong
# resident address, including spectrum_net_join_ui, which is exactly why
# the network screen "worked before and then stopped". The .bin has a real
# recipe and a real timestamp; sprinter-cold-defs-check below is the belt
# to this braces.
$(SPRINTER_COLD_DEFS_ASM): tools/gen_sprinter_cold_defs.py $(SPRINTER_RESIDENT_C_BIN) \
                           | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_cold_defs.py --map $(SPRINTER_RESIDENT_C_MAP) \
		--out $(SPRINTER_COLD_DEFS_ASM)

# The verify step is part of this recipe, not a separate target: it reads
# the .map this very link just produced and fails the build if the entry
# table did not land where the already-linked WIN1 stubs call.
$(SPRINTER_COLD_IMAGE_BIN): $(SPRINTER_COLD_PAGE_SRC) $(SPRINTER_COLD_PAGE_CRT0) \
                            $(SPRINTER_COLD_ENTRY_TABLE) $(SPRINTER_COLD_DEFS_ASM) \
                            $(SPRINTER_PLATFORM_DEFS_ASM) $(SPRINTER_NETFRAME_DEFS_ASM) \
                            $(SPRINTER_LAYOUT_INC) \
                            | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps -clib=default -SO3 -Isrc -I$(SPRINTER_ASM_DIR)/zcc -I$(SPRINTER_GENERATED_DIR) \
		-Ca-I$(SPRINTER_GENERATED_DIR) \
		-DNETCHESSZX_SPRINTER -DNETCHESSZX_FIXED_LOW_RAM \
		-pragma-define:CRT_ORG_CODE=$(SPRINTER_COLD_PAGE_ORG) \
		-crt0=$(patsubst %.asm,%,$(SPRINTER_COLD_PAGE_CRT0)) -m \
		-o $(SPRINTER_COLD_IMAGE_BIN) \
		$(SPRINTER_COLD_PAGE_SRC) $(SPRINTER_PLATFORM_DEFS_ASM) \
		$(SPRINTER_NETFRAME_DEFS_ASM) $(SPRINTER_COLD_DEFS_ASM)
	$(PYTHON) tools/gen_sprinter_cold_thunks.py --mode verify \
		--map $(SPRINTER_COLD_IMAGE_MAP)

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment
# above (macOS ships GNU make 3.81, no grouped-target support).
$(SPRINTER_COLD_IMAGE_MAP): $(SPRINTER_COLD_IMAGE_BIN)

$(SPRINTER_COLD_WIN3_PAGE): tools/make_sprinter_cold_page.py $(SPRINTER_COLD_IMAGE_BIN) \
                            | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/make_sprinter_cold_page.py --image $(SPRINTER_COLD_IMAGE_BIN) \
		--output $(SPRINTER_COLD_WIN3_PAGE)

# The last line is not a self-test: it checks the ARTEFACTS. The cold page
# calls WIN1 by absolute address, so a bridge generated from a stale
# resident_c.map makes the page jump into the middle of whatever moved --
# a silent wrong jump, never a link error. That shipped on 2026-08-15 with
# 42 of 78 symbols wrong (see gen_sprinter_cold_defs.py's verify()).
sprinter-cold-page-check: tools/gen_sprinter_cold_thunks.py tools/gen_sprinter_cold_defs.py \
                          tools/make_sprinter_cold_page.py $(SPRINTER_COLD_IMAGE_BIN)
	$(PYTHON) tools/gen_sprinter_cold_thunks.py --self-test
	$(PYTHON) tools/gen_sprinter_cold_defs.py --self-test
	$(PYTHON) tools/make_sprinter_cold_page.py --self-test
	$(PYTHON) tools/gen_sprinter_cold_defs.py --verify $(SPRINTER_COLD_DEFS_ASM) \
		--map $(SPRINTER_RESIDENT_C_MAP)

# game_protocol.c/mqtt_session_protocol.c (plan D7): portable common/
# protocol source, no platform #ifdef of its own. Linked into the resident
# once here rather than duplicated per-overlay -- control_ovl.c (CONTROL,
# SPECTRUM_OVL_CONTROL=14u) calls netchess_after_prefix/
# netchess_mqtt_session_parse_u16_token and references the NETCHESS_PROTO_*
# string constants; every future overlay that touches the wire protocol
# needs the same functions. SPRINTER_OVERLAY_DEFS_ASM (below) is what lets
# overlay C sources EXTERN this resident copy instead of re-linking it.
SPRINTER_RESIDENT_C_SRC := src/sprinter/main.c \
                           src/sprinter/gui_log_sprinter.c \
                           src/common/protocol/game_protocol_extra.c \
                           src/spectrum/board/board.c \
                           src/common/chess/move_coords.c \
                           src/spectrum/saveload/saveload.c \
                           src/spectrum/restore/restore.c \
                           src/spectrum/fileui/fileui.c \
                           src/spectrum/config/session.c \
                           src/sprinter/session_classify_sprinter.c \
                           src/spectrum/session/event.c \
                           src/spectrum/session/ping.c \
                           src/spectrum/session/direct.c \
                           src/spectrum/session/outgoing.c \
                           src/spectrum/session/poll.c \
                           src/spectrum/platform/text.c \
                           src/spectrum/transport/mqtt_min.c \
                           src/sprinter/transport/unet_link.c \
                           src/spectrum/session/mqtt.c \
                           src/spectrum/transport/mqtt_session_wire.c
# game_protocol.c/keepalive_protocol.c/direct_session_protocol.c moved to
# SPRINTER_NET_FRAME_C_SRC above (S8 steps 4/5 relief) -- every resident
# caller (main.c, game_protocol_extra.c, session/{event,poll,ping,direct,
# outgoing}.c) reaches their entry points through the usual netframe_defs.asm
# bridge, not a direct C link. unet_link.c/mqtt_min.c came back here in S8
# step 8a (see SPRINTER_NET_FRAME_C_SRC's own comment) -- unet_link.c reaches
# the WIN2 blob's nc_* through the same bridge in the other direction now.
# session/{ping,direct,outgoing}.c/platform/text.c/config/session.c stay
# resident -- see SPRINTER_NET_FRAME_C_SRC's own comment on why moving
# them too overran that blob's ~4 KiB ceiling.
SPRINTER_RESIDENT_CRT0 := $(SPRINTER_ASM_DIR)/zcc/resident_crt0.asm
SPRINTER_OVERLAY_LOADER_ASM := $(SPRINTER_ASM_DIR)/zcc/overlay_loader_sprinter.asm
SPRINTER_OVERLAY_ATLAS_TABLE_ASM := $(SPRINTER_ASM_DIR)/zcc/overlay_atlas_table_sprinter.asm
# render_core.asm itself is NOT here any more (S7 step 4): it lives in the
# WIN3 cold page above. What the resident links instead is the three
# per-frame bridges too small to be worth a thunk (render_shim.asm) and the
# generated stubs for everything else (cold_thunks.asm).
SPRINTER_RENDER_SHIM_ASM := $(SPRINTER_ASM_DIR)/zcc/render_shim.asm
SPRINTER_RESIDENT_C_MAP := $(SPRINTER_BUILD_DIR)/resident_c.map

# C_IMAGE_ENTRY_ADDR read from the JSON at recipe time (not hand-duplicated)
# so trampoline.asm's JP target and zcc's CRT_ORG_CODE can never drift apart.
$(SPRINTER_RESIDENT_C_BIN): $(SPRINTER_RESIDENT_C_SRC) $(SPRINTER_RESIDENT_CRT0) \
                            $(SPRINTER_OVERLAY_LOADER_ASM) $(SPRINTER_OVERLAY_ATLAS_TABLE_ASM) \
                            $(SPRINTER_RENDER_SHIM_ASM) $(SPRINTER_COLD_THUNKS_ASM) \
                            $(SPRINTER_PLATFORM_DEFS_ASM) $(SPRINTER_NETFRAME_DEFS_ASM) \
                            $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps -clib=default -SO3 -Isrc -I$(SPRINTER_ASM_DIR)/zcc -I$(SPRINTER_GENERATED_DIR) \
		-DNETCHESSZX_SPRINTER -DNETCHESSZX_FIXED_LOW_RAM \
		-pragma-define:CRT_ORG_CODE=$$($(PYTHON) tools/gen_sprinter_layout.py \
			--layout $(SPRINTER_LAYOUT_JSON) --print-symbol C_IMAGE_ENTRY_ADDR) \
		-crt0=$(patsubst %.asm,%,$(SPRINTER_RESIDENT_CRT0)) -m \
		-o $(SPRINTER_RESIDENT_C_BIN) \
		$(SPRINTER_RESIDENT_C_SRC) $(SPRINTER_OVERLAY_LOADER_ASM) \
		$(SPRINTER_RENDER_SHIM_ASM) $(SPRINTER_COLD_THUNKS_ASM) \
		$(SPRINTER_PLATFORM_DEFS_ASM) $(SPRINTER_NETFRAME_DEFS_ASM)

# Mirror rule, not a grouped "&:" target -- see the fixed_layout.h comment
# above (macOS ships GNU make 3.81, no grouped-target support).
$(SPRINTER_RESIDENT_C_MAP): $(SPRINTER_RESIDENT_C_BIN)

SPRINTER_OVERLAY_DEFS_ASM := $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.asm

# Same .bin-not-.map dependency, for the same reason (see cold_defs above).
$(SPRINTER_OVERLAY_DEFS_ASM): tools/gen_sprinter_overlay_defs.py $(SPRINTER_RESIDENT_C_BIN) \
                              | $(SPRINTER_GENERATED_DIR)
	$(PYTHON) tools/gen_sprinter_overlay_defs.py --map $(SPRINTER_RESIDENT_C_MAP) \
		--out $(SPRINTER_OVERLAY_DEFS_ASM)

sprinter-overlay-defs-check: tools/gen_sprinter_overlay_defs.py
	$(PYTHON) tools/gen_sprinter_overlay_defs.py --self-test

# CONTROL (SPECTRUM_OVL_CONTROL=14u, plan D7): first real overlay ported to
# Sprinter, same src/spectrum/overlay/control_ovl.c ZX links, proving the
# zcc+z80asm overlay pipeline end to end (D3's lowram_map.h
# NETCHESSZX_SPRINTER branch gets its first real consumer here). Embedded
# in the assets page at the same slot (36-43) the S3-successor proof
# payload (overlay_probe_sprinter.asm, retired) used to hold, and wired
# into overlay_atlas_table_sprinter.asm's real (now dense, 15-entry) atlas
# at id 14. Ids 0-13 stay unported placeholders -- those overlays need
# render_core (RULES/BOARD/GUI_LOG/STATUS/INPUT_EDIT, substep 3) or are out
# of S5's scope entirely (S6/S7/S8/S9); the current assets page has room
# for exactly one 2 KiB overlay slot, so a real subset atlas beyond this
# one entry needs its own page(s) first, the same way piece_page1/
# piece_page2 already give bench/piece tiles a second and third WIN0 page
# -- that allocation is a separate decision, deferred (port.md).
SPRINTER_OVL_CONTROL_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_control_sprinter.asm
SPRINTER_OVL_CFLAGS := -clib=default -SO3 -Isrc -I$(SPRINTER_GENERATED_DIR) \
                       -DNETCHESSZX_SPRINTER -DNETCHESSZX_FIXED_LOW_RAM

# zcc's own link driver pulls the z88dk clib archive (l_gint/l_eq/... runtime
# helpers -clib=default's codegen calls for generic comparisons, and which
# actually live in the crt0 archive, not the platform clib) in
# automatically; a raw z80asm -r link like this one and ZX's overlay link
# (asm/overlay/*/entry_*.asm) bypasses that driver, so both archives have to
# be named explicitly. Derived from the zcc binary's own location, not
# $ZCCCFG (may be unset in CI), matching how it actually resolves per `zcc -v`.
SPRINTER_Z88DK_ROOT := $(patsubst %/bin/,%,$(dir $(shell command -v $(ZCC))))
SPRINTER_OVL_LIBDIRS := -L$(SPRINTER_Z88DK_ROOT)/lib/clibs

$(SPRINTER_OVL_CONTROL_BIN): $(SPRINTER_OVL_CONTROL_ENTRY_ASM) src/spectrum/overlay/control_ovl.c \
                             $(SPRINTER_OVERLAY_DEFS_ASM) $(SPRINTER_LAYOUT_H) \
                             $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/spectrum/overlay/control_ovl.c \
		-o $(SPRINTER_BUILD_DIR)/control_ovl.o
	$(Z80ASM) $(SPRINTER_OVL_CONTROL_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVERLAY_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/gen_sprinter_layout.py --layout $(SPRINTER_LAYOUT_JSON) \
			--print-symbol OVL_SLOT_ADDR) \
		-o=$(SPRINTER_OVL_CONTROL_BIN) $(SPRINTER_OVL_LIBDIRS) -lpps_clib -lz80_crt0 \
		$(SPRINTER_ASM_DIR)/zcc/entry_control_sprinter.o $(SPRINTER_BUILD_DIR)/control_ovl.o \
		$(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_control_sprinter.o $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o

sprinter-overlay-control-check: $(SPRINTER_OVL_CONTROL_BIN) tests/tools/test_sprinter_overlay_control.py
	$(PYTHON) tests/tools/test_sprinter_overlay_control.py

# RULES (SPECTRUM_OVL_RULES=0u, plan D7, S5 substep 3b): entries 0/1 only
# (play/check) -- rules_stub_sprinter.asm's own header explains why hints
# (2/3) are not ported yet. Pure Z80, no C and no resident-symbol
# dependency (unlike BOARD below), so this link needs platform_defs.asm
# (for LOWRAM_OVERLAY_SCRATCH_ADDR) but neither overlay_defs_sprinter.asm
# nor the clib/crt0 archives CONTROL/BOARD need for their C code. Linked at
# WIN3 slot 0 (#C000) and mapped, not copied -- plan D7-bis, see
# tools/make_sprinter_overlay_page.py and the atlas table's own header.
SPRINTER_OVL_RULES_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_rules_sprinter.asm
SPRINTER_OVL_RULES_STUB_ASM := $(SPRINTER_ASM_DIR)/zcc/rules_stub_sprinter.asm

$(SPRINTER_OVL_RULES_BIN): $(SPRINTER_OVL_RULES_ENTRY_ASM) $(SPRINTER_OVL_RULES_STUB_ASM) \
                           $(SPRINTER_PLATFORM_DEFS_ASM) $(SPRINTER_LAYOUT_H) \
                           $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(Z80ASM) $(SPRINTER_OVL_RULES_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVL_RULES_STUB_ASM)
	$(Z80ASM) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org RULES) \
		-o=$(SPRINTER_OVL_RULES_BIN) \
		$(SPRINTER_ASM_DIR)/zcc/entry_rules_sprinter.o $(SPRINTER_ASM_DIR)/zcc/rules_stub_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_rules_sprinter.o $(SPRINTER_ASM_DIR)/zcc/rules_stub_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o

sprinter-overlay-rules-check: $(SPRINTER_OVL_RULES_BIN)

# BOARD (SPECTRUM_OVL_BOARD=1u, plan D7, S5 substep 3b): all four entries.
# src/spectrum/overlay/board_apply_ovl.c is untouched, shared byte-for-byte
# with ZX/Next; board_helpers_sprinter.c replaces asm/overlay/board/
# helpers.asm (SDCC/IY-only stack ABI, incompatible with Sprinter's classic
# z88dk C -- see that file's own header). Needs overlay_defs_sprinter.asm
# for _side_to_move/_castle_rights/_ep_square (board.c resident globals,
# now linked into the resident -- SPRINTER_RESIDENT_C_SRC above),
# platform_defs.asm for LOWRAM_CHESS_BOARD_ADDR (entry_board_sprinter.asm's
# hand-ported snapshot-save routine), and the clib/crt0 archives (its C
# code needs the runtime helpers CONTROL's own comment on
# SPRINTER_OVL_LIBDIRS explains).
SPRINTER_OVL_BOARD_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_board_sprinter.asm
SPRINTER_OVL_BOARD_HELPERS_C := $(SPRINTER_ASM_DIR)/zcc/board_helpers_sprinter.c

$(SPRINTER_OVL_BOARD_BIN): $(SPRINTER_OVL_BOARD_ENTRY_ASM) src/spectrum/overlay/board_apply_ovl.c \
                           $(SPRINTER_OVL_BOARD_HELPERS_C) $(SPRINTER_OVERLAY_DEFS_ASM) \
                           $(SPRINTER_PLATFORM_DEFS_ASM) \
                           $(SPRINTER_LAYOUT_H) $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/spectrum/overlay/board_apply_ovl.c \
		-o $(SPRINTER_BUILD_DIR)/board_apply_ovl.o
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c $(SPRINTER_OVL_BOARD_HELPERS_C) \
		-o $(SPRINTER_BUILD_DIR)/board_helpers_sprinter.o
	$(Z80ASM) $(SPRINTER_OVL_BOARD_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVERLAY_DEFS_ASM)
	$(Z80ASM) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org BOARD) \
		-o=$(SPRINTER_OVL_BOARD_BIN) $(SPRINTER_OVL_LIBDIRS) -lpps_clib -lz80_crt0 \
		$(SPRINTER_ASM_DIR)/zcc/entry_board_sprinter.o $(SPRINTER_BUILD_DIR)/board_apply_ovl.o \
		$(SPRINTER_BUILD_DIR)/board_helpers_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_board_sprinter.o $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o

sprinter-overlay-board-check: $(SPRINTER_OVL_BOARD_BIN)

# SAVELOAD (SPECTRUM_OVL_SAVELOAD=10u, S6 plan step 3): all three entries.
# src/spectrum/overlay/saveload_ovl.c is the same source ZX links (one
# ifdef'd line, its own SAVELOAD_DIR -> spectrum_platform_save_dir()
# branch); needs platform_defs.asm for the esx_*/fat_date/fat_time/
# background_drain/save_dir bridge (asm/sprinter/dss_fileio.asm, S6 plan
# step 1) and the clib/crt0 archives (CONTROL's own comment on
# SPRINTER_OVL_LIBDIRS explains why).
SPRINTER_OVL_SAVELOAD_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_saveload_sprinter.asm

$(SPRINTER_OVL_SAVELOAD_BIN): $(SPRINTER_OVL_SAVELOAD_ENTRY_ASM) src/spectrum/overlay/saveload_ovl.c \
                              $(SPRINTER_OVERLAY_DEFS_ASM) $(SPRINTER_PLATFORM_DEFS_ASM) \
                              $(SPRINTER_LAYOUT_H) $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/spectrum/overlay/saveload_ovl.c \
		-o $(SPRINTER_BUILD_DIR)/saveload_ovl.o
	$(Z80ASM) $(SPRINTER_OVL_SAVELOAD_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVERLAY_DEFS_ASM)
	$(Z80ASM) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org SAVELOAD) \
		-o=$(SPRINTER_OVL_SAVELOAD_BIN) $(SPRINTER_OVL_LIBDIRS) -lpps_clib -lz80_crt0 \
		$(SPRINTER_ASM_DIR)/zcc/entry_saveload_sprinter.o $(SPRINTER_BUILD_DIR)/saveload_ovl.o \
		$(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_saveload_sprinter.o $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o

sprinter-overlay-saveload-check: $(SPRINTER_OVL_SAVELOAD_BIN)

# RESTORE (SPECTRUM_OVL_RESTORE=11u, S6 plan step 3): both entries.
# src/spectrum/overlay/restore_ovl.c is the same source ZX links, byte-for-
# byte unchanged (a pure b64+CRC codec, no I/O, no platform ifdef, no
# resident-symbol or platform_core dependency at all) -- overlay_defs_
# sprinter.asm/platform_defs.asm are linked anyway for consistency with
# every other overlay bin (defc constants cost zero bytes, S5's own
# precedent for CONTROL).
SPRINTER_OVL_RESTORE_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_restore_sprinter.asm

$(SPRINTER_OVL_RESTORE_BIN): $(SPRINTER_OVL_RESTORE_ENTRY_ASM) src/spectrum/overlay/restore_ovl.c \
                             $(SPRINTER_OVERLAY_DEFS_ASM) $(SPRINTER_PLATFORM_DEFS_ASM) \
                             $(SPRINTER_LAYOUT_H) $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/spectrum/overlay/restore_ovl.c \
		-o $(SPRINTER_BUILD_DIR)/restore_ovl.o
	$(Z80ASM) $(SPRINTER_OVL_RESTORE_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVERLAY_DEFS_ASM)
	$(Z80ASM) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org RESTORE) \
		-o=$(SPRINTER_OVL_RESTORE_BIN) $(SPRINTER_OVL_LIBDIRS) -lpps_clib -lz80_crt0 \
		$(SPRINTER_ASM_DIR)/zcc/entry_restore_sprinter.o $(SPRINTER_BUILD_DIR)/restore_ovl.o \
		$(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_restore_sprinter.o $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o

sprinter-overlay-restore-check: $(SPRINTER_OVL_RESTORE_BIN)

# FILEUI (SPECTRUM_OVL_FILEUI=13u, S6 plan step 4): both entries.
# src/spectrum/overlay/fileui_ovl.c is the same source ZX links (one
# ifdef'd line, its own fileui_dir -> spectrum_platform_save_dir()
# branch); needs platform_defs.asm for the esx_* bridge (directory scan)
# and the clib/crt0 archives (CONTROL's own comment on SPRINTER_OVL_LIBDIRS
# explains why).
SPRINTER_OVL_FILEUI_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_fileui_sprinter.asm

$(SPRINTER_OVL_FILEUI_BIN): $(SPRINTER_OVL_FILEUI_ENTRY_ASM) src/spectrum/overlay/fileui_ovl.c \
                            $(SPRINTER_OVERLAY_DEFS_ASM) $(SPRINTER_PLATFORM_DEFS_ASM) \
                            $(SPRINTER_LAYOUT_H) $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/spectrum/overlay/fileui_ovl.c \
		-o $(SPRINTER_BUILD_DIR)/fileui_ovl.o
	$(Z80ASM) $(SPRINTER_OVL_FILEUI_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVERLAY_DEFS_ASM)
	$(Z80ASM) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org FILEUI) \
		-o=$(SPRINTER_OVL_FILEUI_BIN) $(SPRINTER_OVL_LIBDIRS) -lpps_clib -lz80_crt0 \
		$(SPRINTER_ASM_DIR)/zcc/entry_fileui_sprinter.o $(SPRINTER_BUILD_DIR)/fileui_ovl.o \
		$(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_fileui_sprinter.o $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o

sprinter-overlay-fileui-check: $(SPRINTER_OVL_FILEUI_BIN)

# NET (SPECTRUM_OVL_NET_CONNECT=3u, S8 steps 8b/8d): five entries -- the
# MQTT connect lifecycle (src/sprinter/net_mqtt_ui_sprinter.c) plus the
# DIRECT-join/config screen moved here from the WIN3 cold page
# (src/sprinter/net_ui_sprinter.c). Lives on WIN3 overlay PAGE 2 (--page 2
# below), not page 1 -- see tools/make_sprinter_overlay_page.py's own
# header for why. Needs overlay_defs_sprinter.asm (net_ui_sprinter.c
# reaches spectrum_render_fileui_frame/spectrum_render_ikkle_at through it,
# the same bridge FILEUI uses; net_mqtt_ui_sprinter.c's CONNACK/SUBACK wait
# reaches the WIN2 blob's nc_mqtt_* reassembler through this SAME file --
# resident_c.bin already links netframe_defs.asm directly, so its PUBLIC
# nc_mqtt_* defc's appear in resident_c.map too, exactly like spectrum_net_
# background_drain's own entry above; linking netframe_defs.asm into THIS
# overlay as well, instead, would duplicate-define every game_protocol.c
# string constant both files bridge) and platform_defs.asm (ng_*/
# frame_wait/key_poll, net_gate.asm/im2_s1.asm), plus the clib/crt0
# archives (CONTROL's own comment on SPRINTER_OVL_LIBDIRS explains why).
SPRINTER_OVL_NET_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_net_sprinter.asm

$(SPRINTER_OVL_NET_BIN): $(SPRINTER_OVL_NET_ENTRY_ASM) src/sprinter/net_ui_sprinter.c \
                         src/sprinter/net_mqtt_ui_sprinter.c \
                         $(SPRINTER_OVERLAY_DEFS_ASM) $(SPRINTER_PLATFORM_DEFS_ASM) \
                         $(SPRINTER_LAYOUT_H) $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/sprinter/net_ui_sprinter.c \
		-o $(SPRINTER_BUILD_DIR)/net_ui_sprinter.o
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/sprinter/net_mqtt_ui_sprinter.c \
		-o $(SPRINTER_BUILD_DIR)/net_mqtt_ui_sprinter.o
	$(Z80ASM) $(SPRINTER_OVL_NET_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVERLAY_DEFS_ASM)
	$(Z80ASM) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org NET) \
		-o=$(SPRINTER_OVL_NET_BIN) $(SPRINTER_OVL_LIBDIRS) -lpps_clib -lz80_crt0 \
		$(SPRINTER_ASM_DIR)/zcc/entry_net_sprinter.o $(SPRINTER_BUILD_DIR)/net_ui_sprinter.o \
		$(SPRINTER_BUILD_DIR)/net_mqtt_ui_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_net_sprinter.o $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o

sprinter-overlay-net-check: $(SPRINTER_OVL_NET_BIN)

# INPUT_EDIT (SPECTRUM_OVL_INPUT_EDIT=9u, S9 chat pass): the line editor and
# the chat log both live here (src/sprinter/chat_sprinter.c's own header
# explains why one overlay owns both). Lives on WIN3 overlay PAGE 2 (--page
# 2 below), in what used to be RESERVE2's own slot -- tools/make_sprinter_
# overlay_page.py's own header. Needs overlay_defs_sprinter.asm (chat_
# sprinter.c reaches spectrum_render_input/_chat/_chat_at, spectrum_net_
# payload_scratch/_send_text and net_chat_blocked through it, the same
# bridge NET's own net_ui_sprinter.c uses above) but NOT platform_defs.asm
# -- unlike net_ui_sprinter.c, this file never calls an ng_*/frame_wait/
# key_poll primitive directly, only the resident-symbol bridge.
SPRINTER_OVL_INPUT_EDIT_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_input_edit_sprinter.asm

$(SPRINTER_OVL_INPUT_EDIT_BIN): $(SPRINTER_OVL_INPUT_EDIT_ENTRY_ASM) src/sprinter/chat_sprinter.c \
                         $(SPRINTER_OVERLAY_DEFS_ASM) \
                         $(SPRINTER_LAYOUT_H) $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(ZCC) +pps $(SPRINTER_OVL_CFLAGS) -c src/sprinter/chat_sprinter.c \
		-o $(SPRINTER_BUILD_DIR)/chat_sprinter.o
	$(Z80ASM) $(SPRINTER_OVL_INPUT_EDIT_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVERLAY_DEFS_ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org INPUT_EDIT) \
		-o=$(SPRINTER_OVL_INPUT_EDIT_BIN) $(SPRINTER_OVL_LIBDIRS) -lpps_clib -lz80_crt0 \
		$(SPRINTER_ASM_DIR)/zcc/entry_input_edit_sprinter.o $(SPRINTER_BUILD_DIR)/chat_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_input_edit_sprinter.o $(SPRINTER_GENERATED_DIR)/overlay_defs_sprinter.o

sprinter-overlay-input-edit-check: $(SPRINTER_OVL_INPUT_EDIT_BIN)

# ABOUT (SPECTRUM_OVL_ABOUT=12u, S9 About pass): the full-screen artwork
# painter. Also page 2, in the first half of what was left of RESERVE2.
# Pure asm (see about_sprinter.asm's own header for why), so unlike the
# overlays above there is no zcc step -- but it does need two GENERATED
# sources: the artwork's palette as z80asm defb's, and the version string
# in the same dialect. Needs platform_defs.asm (it reaches gfx_draw_tile,
# text_print, palette_apply_from and the tile_* block through it) but not
# overlay_defs_sprinter.asm -- it calls no resident C at all.
SPRINTER_OVL_ABOUT_ENTRY_ASM := $(SPRINTER_ASM_DIR)/zcc/entry_about_sprinter.asm
SPRINTER_OVL_ABOUT_BODY_ASM := $(SPRINTER_ASM_DIR)/zcc/about_sprinter.asm

$(SPRINTER_OVL_ABOUT_BIN): $(SPRINTER_OVL_ABOUT_ENTRY_ASM) $(SPRINTER_OVL_ABOUT_BODY_ASM) \
                         $(SPRINTER_PLATFORM_DEFS_ASM) $(SPRINTER_ABOUT_PAL_INC) \
                         $(SPRINTER_VERSION_INC_Z80ASM) \
                         $(SPRINTER_LAYOUT_H) $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(Z80ASM) $(SPRINTER_OVL_ABOUT_ENTRY_ASM)
	$(Z80ASM) $(SPRINTER_OVL_ABOUT_BODY_ASM)
	$(Z80ASM) $(SPRINTER_PLATFORM_DEFS_ASM)
	$(Z80ASM) $(SPRINTER_ABOUT_PAL_INC)
	$(Z80ASM) $(SPRINTER_VERSION_INC_Z80ASM)
	$(Z80ASM) -b -r$$($(PYTHON) tools/make_sprinter_overlay_page.py --print-org ABOUT) \
		-o=$(SPRINTER_OVL_ABOUT_BIN) \
		$(SPRINTER_ASM_DIR)/zcc/entry_about_sprinter.o $(SPRINTER_ASM_DIR)/zcc/about_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o \
		$(SPRINTER_GENERATED_DIR)/about_palette.o \
		$(SPRINTER_GENERATED_DIR)/sprinter_version_z80asm.o
	rm -f $(SPRINTER_ASM_DIR)/zcc/entry_about_sprinter.o $(SPRINTER_ASM_DIR)/zcc/about_sprinter.o \
		$(SPRINTER_GENERATED_DIR)/platform_defs.o $(SPRINTER_GENERATED_DIR)/about_palette.o \
		$(SPRINTER_GENERATED_DIR)/sprinter_version_z80asm.o

sprinter-overlay-about-check: $(SPRINTER_OVL_ABOUT_BIN)

# WIN3 overlay page 1 (tools/make_sprinter_overlay_page.py, plan D7-bis, S6
# plan step 2): RULES/BOARD/SAVELOAD/RESTORE/FILEUI's own bytes, each linked
# at its own ORG inside #C000-#FFFF and packed per that tool's declarative
# LAYOUT table (variable-size slots, not a uniform 4 KiB one -- see that
# file's own header). Published to HDR as the fourth asset page and read by
# asm/sprinter/buffers.asm's bench_init into ovl_win3_page; the loader maps
# it into WIN3 with a single OUT instead of copying it.
SPRINTER_OVL_WIN3_PAGE := $(SPRINTER_BUILD_DIR)/ovl_win3_page.bin

$(SPRINTER_OVL_WIN3_PAGE): tools/make_sprinter_overlay_page.py $(SPRINTER_OVL_RULES_BIN) \
                       $(SPRINTER_OVL_BOARD_BIN) $(SPRINTER_OVL_SAVELOAD_BIN) \
                       $(SPRINTER_OVL_RESTORE_BIN) $(SPRINTER_OVL_FILEUI_BIN) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/make_sprinter_overlay_page.py \
		--rules-bin $(SPRINTER_OVL_RULES_BIN) --board-bin $(SPRINTER_OVL_BOARD_BIN) \
		--saveload-bin $(SPRINTER_OVL_SAVELOAD_BIN) --restore-bin $(SPRINTER_OVL_RESTORE_BIN) \
		--fileui-bin $(SPRINTER_OVL_FILEUI_BIN) \
		--output $(SPRINTER_OVL_WIN3_PAGE)

# WIN3 overlay page 2 (S8 step 8b, S9 chat pass): NET + INPUT_EDIT, plus a
# hard reserve -- see tools/make_sprinter_overlay_page.py's LAYOUT2 for why
# this page exists at all instead of squeezing NET/INPUT_EDIT into page 1's
# own slack. Published to HDR as the SIXTH asset page (appended last -- see
# buffers.asm's own bench_init comment for why this order matters) and read
# into ovl_win3_page2; overlay_atlas_table_sprinter.asm's ovl_atlas_page_
# table is what makes ids 3/9 alone read this cell instead of ovl_win3_page.
SPRINTER_OVL_WIN3_PAGE2 := $(SPRINTER_BUILD_DIR)/ovl_win3_page2.bin

$(SPRINTER_OVL_WIN3_PAGE2): tools/make_sprinter_overlay_page.py $(SPRINTER_OVL_NET_BIN) \
                       $(SPRINTER_OVL_INPUT_EDIT_BIN) $(SPRINTER_OVL_ABOUT_BIN) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/make_sprinter_overlay_page.py --page 2 \
		--net-bin $(SPRINTER_OVL_NET_BIN) \
		--input_edit-bin $(SPRINTER_OVL_INPUT_EDIT_BIN) \
		--about-bin $(SPRINTER_OVL_ABOUT_BIN) \
		--output $(SPRINTER_OVL_WIN3_PAGE2)

$(SPRINTER_RESIDENT_BIN): $(SPRINTER_TRAMPOLINE_BIN) $(SPRINTER_RESIDENT_C_BIN) \
                          $(SPRINTER_PLATFORM_PRIMITIVES_BIN) $(SPRINTER_NET_FRAME_C_BIN) \
                          tools/make_sprinter_resident.py \
                          $(SPRINTER_LAYOUT_JSON) | $(SPRINTER_BUILD_DIR)
	$(PYTHON) tools/make_sprinter_resident.py --layout $(SPRINTER_LAYOUT_JSON) \
		--trampoline $(SPRINTER_TRAMPOLINE_BIN) --resident-c $(SPRINTER_RESIDENT_C_BIN) \
		--platform-primitives $(SPRINTER_PLATFORM_PRIMITIVES_BIN) \
		--net-frame-c $(SPRINTER_NET_FRAME_C_BIN) --output $(SPRINTER_RESIDENT_BIN)

$(SPRINTER_EXE): $(SPRINTER_LOADER_BIN) $(SPRINTER_RESIDENT_BIN) $(SPRINTER_ASSETS_PAGE) \
                 $(SPRINTER_PIECE_PAGE1) $(SPRINTER_PIECE_PAGE2) $(SPRINTER_OVL_WIN3_PAGE) \
                 $(SPRINTER_COLD_WIN3_PAGE) $(SPRINTER_OVL_WIN3_PAGE2) \
                 $(SPRINTER_ABOUT_PAGE0) $(SPRINTER_ABOUT_PAGE1) \
                 $(SPRINTER_ABOUT_PAGE2) $(SPRINTER_ABOUT_PAGE3) \
                 tools/make_sprinter_exe.py $(SPRINTER_LAYOUT_JSON) VERSION $(SPRINTER_DLLS)
	mkdir -p $(SPRINTER_RELEASE_DIR)
	$(PYTHON) tools/make_sprinter_exe.py --loader $(SPRINTER_LOADER_BIN) \
		--resident $(SPRINTER_RESIDENT_BIN) --assets $(SPRINTER_ASSETS_PAGE) \
		--assets $(SPRINTER_PIECE_PAGE1) --assets $(SPRINTER_PIECE_PAGE2) \
		--assets $(SPRINTER_OVL_WIN3_PAGE) --assets $(SPRINTER_COLD_WIN3_PAGE) \
		--assets $(SPRINTER_OVL_WIN3_PAGE2) \
		--assets $(SPRINTER_ABOUT_PAGE0) --assets $(SPRINTER_ABOUT_PAGE1) \
		--assets $(SPRINTER_ABOUT_PAGE2) --assets $(SPRINTER_ABOUT_PAGE3) \
		--layout $(SPRINTER_LAYOUT_JSON) \
		--version-file VERSION --output $(SPRINTER_EXE)
	cp $(SPRINTER_DLLS) $(SPRINTER_RELEASE_DIR)/

exe: sprinter-deps-check sprinter-layout-check $(SPRINTER_EXE)

sprinter-resident-test: tests/tools/test_sprinter_resident.py $(SPRINTER_RESIDENT_BIN) \
                        tests/tools/test_sprinter_overlay_dispatch.py $(SPRINTER_RESIDENT_C_BIN)
	$(PYTHON) tests/tools/test_sprinter_resident.py
	$(PYTHON) tests/tools/test_sprinter_overlay_dispatch.py

# Depends on the compiled blob: tests/sprinter/z80/t_net_frame_blob.asm
# INCBINs build/sprinter/net_frame_c.bin and calls into it at the addresses
# its own .map reports, so the MQTT reassembler under test is byte-identical
# to the one in SHATRANJ.EXE (see that test's banner for why a gcc-built host
# test was not enough).
# $(SPRINTER_RESIDENT_BIN) is a dependency for t_net_mqtt_read.asm, which
# INCBINs the spliced resident image and drives its MQTT read path through
# the bytes that ship (that test's own banner has the why).
sprinter-z80-test: tools/run_sprinter_z80_tests.sh $(SPRINTER_LAYOUT_INC) \
                   $(SPRINTER_RENDER_LAYOUT_INC) $(SPRINTER_PALETTE_INC) \
                   $(SPRINTER_NET_FRAME_C_BIN) $(SPRINTER_RESIDENT_BIN)
	tools/run_sprinter_z80_tests.sh

# net_frame.c (S7 step 2) builds and behaves identically under gcc: no
# target-only header, so this is a real behavioural proof of the line-
# framing core, not just a compile check (mirrors GAME_PROTOCOL_TEST's
# shape for src/common/protocol/*.c). mqtt_min.c (S8 step 7) joins it HERE
# ONLY -- not the Sprinter target build above, see that source list's own
# comment on why -- so the host round trip (net_frame.c's nc_mqtt_*
# reassembler handing complete packets to spectrum_mqtt_type()/
# spectrum_mqtt_parse_publish()) still gets proven against the real codec,
# at zero byte cost, ahead of step 8 actually linking it on-target.
SPRINTER_NET_FRAME_HOST_TEST := $(SPRINTER_BUILD_DIR)/netchesszx_sprinter_net_frame_test.exe
SPRINTER_NET_FRAME_HOST_TEST_SRC := src/sprinter/transport/net_frame.c \
                                    src/spectrum/transport/mqtt_min.c \
                                    tests/sprinter/host/test_net_frame.c

$(SPRINTER_NET_FRAME_HOST_TEST): $(SPRINTER_NET_FRAME_HOST_TEST_SRC) \
                                  src/sprinter/transport/net_frame.h \
                                  src/spectrum/transport/mqtt_min.h | $(SPRINTER_BUILD_DIR)
	$(CC) $(CFLAGS) $(SPRINTER_NET_FRAME_HOST_TEST_SRC) -o $@

sprinter-host-test: $(SPRINTER_NET_FRAME_HOST_TEST)
	./$(SPRINTER_NET_FRAME_HOST_TEST)

SPRINTER_SIZE_REPORT_JSON := $(SPRINTER_BUILD_DIR)/size_report.json
SPRINTER_SIZE_REPORT_MD := $(SPRINTER_BUILD_DIR)/size_report.md

sprinter-size-report: exe tools/gen_sprinter_size_report.py $(SPRINTER_RESIDENT_C_BIN) \
                       $(SPRINTER_RESIDENT_BIN) $(SPRINTER_PLATFORM_PRIMITIVES_BIN) \
                       $(SPRINTER_OVL_CONTROL_BIN) $(SPRINTER_OVL_RULES_BIN) \
                       $(SPRINTER_OVL_BOARD_BIN) $(SPRINTER_OVL_INPUT_EDIT_BIN) \
                       $(SPRINTER_OVL_WIN3_PAGE)
	$(PYTHON) tools/gen_sprinter_size_report.py --self-test
	$(PYTHON) tools/gen_sprinter_size_report.py \
		--resident-c-map $(SPRINTER_RESIDENT_C_MAP) \
		--resident-c-bin $(SPRINTER_RESIDENT_C_BIN) \
		--resident-bin $(SPRINTER_RESIDENT_BIN) \
		--platform-primitives-bin $(SPRINTER_PLATFORM_PRIMITIVES_BIN) \
		--ovl-control-bin $(SPRINTER_OVL_CONTROL_BIN) \
		--ovl-rules-bin $(SPRINTER_OVL_RULES_BIN) \
		--ovl-board-bin $(SPRINTER_OVL_BOARD_BIN) \
		--ovl-input-edit-bin $(SPRINTER_OVL_INPUT_EDIT_BIN) \
		--ovl-win3-page $(SPRINTER_OVL_WIN3_PAGE) \
		--c-image-base $$($(PYTHON) tools/gen_sprinter_layout.py --layout $(SPRINTER_LAYOUT_JSON) --print-symbol C_IMAGE_ENTRY_ADDR) \
		--win1-end $$($(PYTHON) tools/gen_sprinter_layout.py --layout $(SPRINTER_LAYOUT_JSON) --print-symbol WIN1_END) \
		--ovl-slot-size $$($(PYTHON) tools/gen_sprinter_layout.py --layout $(SPRINTER_LAYOUT_JSON) --print-symbol OVL_SLOT_SIZE) \
		--json $(SPRINTER_SIZE_REPORT_JSON) --markdown $(SPRINTER_SIZE_REPORT_MD)

sprinter-smoke-image: exe tools/make_sprinter_smoke_image.py
	$(PYTHON) tools/make_sprinter_smoke_image.py --exe $(SPRINTER_EXE) \
		--dll extern/esp_net/UNETESP.DLL --dll extern/rtl_net/UNETRTL.DLL \
		--output $(SPRINTER_SMOKE_IMG)

sprinter-hw-zip: exe tools/make_sprinter_hw_zip.py
	$(PYTHON) tools/make_sprinter_hw_zip.py --exe $(SPRINTER_EXE) \
		--dll extern/esp_net/UNETESP.DLL --dll extern/rtl_net/UNETRTL.DLL \
		--output $(SPRINTER_HW_ZIP)

sprinter-check: sprinter-deps-check sprinter-tools-test sprinter-layout-check \
                sprinter-gates sprinter-section-gate sprinter-crt0-check \
                sprinter-platform-defs-check sprinter-netframe-defs-check \
                sprinter-sccz80-codegen-check \
                sprinter-cold-page-check \
                sprinter-overlay-defs-check \
                sprinter-overlay-control-check sprinter-overlay-rules-check \
                sprinter-overlay-board-check sprinter-overlay-saveload-check \
                sprinter-overlay-restore-check sprinter-overlay-fileui-check \
                sprinter-overlay-net-check sprinter-overlay-input-edit-check \
                sprinter-z80-test sprinter-resident-test sprinter-host-test \
                sprinter-size-report sprinter-smoke-image
	$(PYTHON) tools/make_sprinter_smoke_image.py --exe $(SPRINTER_EXE) \
		--dll extern/esp_net/UNETESP.DLL --dll extern/rtl_net/UNETRTL.DLL \
		--output $(SPRINTER_SMOKE_IMG).rebuild > /dev/null
	cmp $(SPRINTER_SMOKE_IMG) $(SPRINTER_SMOKE_IMG).rebuild
	@rm -f $(SPRINTER_SMOKE_IMG).rebuild
	@printf "[OK] sprinter-check: deps, EXE format, smoke image (deterministic)\n"

clean-sprinter:
ifneq ($(CLIENT_HOST_IS_WINDOWS),)
	$(POWERSHELL) -NoProfile -Command "Remove-Item -Recurse -Force -ErrorAction Ignore '$(SPRINTER_BUILD_DIR)', '$(SPRINTER_RELEASE_DIR)'"
else
	rm -rf $(SPRINTER_BUILD_DIR) $(SPRINTER_RELEASE_DIR)
endif
