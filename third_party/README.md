# Third-Party Code

External source lives in `extern/` as pinned git submodules. The exact commits,
binary sizes and SHA-256 values used by the Sprinter build are machine-readable
in [`docs/sprinter-dependencies.json`](../docs/sprinter-dependencies.json).

| Component | Provenance | License/provenance note | Distribution |
| --- | --- | --- | --- |
| libman 1.3 | `witchcraft2001/sprinter-libman`, derived from Alexander Shabarshin's 2002 libman | Historical copyright and original documentation are retained in the submodule; the repository does not currently contain a standalone license file | Source-only build dependency, linked into the Sprinter EXE |
| UNETESP | `witchcraft2001/sprinter_net` | BSD-3-Clause; see `extern/esp_net/LICENSE` | Not copied to `release/`; included only in the generated smoke image |
| UNETRTL | `witchcraft2001/sprinter-rtl8019a` | Source files identify the Sprinter network code as BSD-3-Clause; upstream does not currently contain a root license file | Not copied to `release/`; included only in the generated smoke image |
| GFX640 / AFNT640 | `witchcraft2001/sprinter-libs` | Upstream sources and binary provenance are pinned; upstream does not currently contain a standalone license file | Both pinned DLLs are copied to the Sprinter release |

No uNet DLL is rebuilt from a dirty checkout. `make sprinter-deps-check`
rejects modified submodules and verifies every committed binary before it can
be used by the stage-0 build.
