# tests/phosh

phoc and phosh run headless on the host against a fake launcherctl (`docs/PHOSH.md`, "Testing").
`run-headless.sh` builds both with the recipes' patch sets, starts everything and runs every
`test-*.sh` here; `run-headless.sh --self-test` checks only the fake (no build needed).

Writing a bridge test, in three lines:

1. Add `tests/phosh/test-NN-name.sh` that starts with `. "$TL_SCRIPT_DIR/lib.sh"`; it runs under `set -e` with phosh up and the fake's endpoint and token in `~/.launcherctl/`.
2. Drive the bridge with `fake_push battery '{"percentage":9,...}'` (an SSE event on `/v1/watch`) or `fake_control_post /state/rotation '{...}'`, and check what phosh did with `wait_for 10 "what" <command>`, `on_bus <name>` and `gdbus`.
3. Check what phosh sent back with `fake_calls`, `fake_call_count POST /v1/vibrate` and `fake_unexpected`; call `fake_reset` first to start from an empty log.
