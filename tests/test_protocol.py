"""Wire protocol encoding and error mapping."""

from __future__ import annotations

import json

import pytest

from aseprite_mcp.bridge.protocol import (
    BridgeError,
    ErrorCode,
    decode_message,
    encode_request,
    error_from_response,
)


class TestEncode:
    def test_shape_matches_the_spec(self):
        payload = json.loads(encode_request(42, "frame.duplicate", {"frame": 3}))
        assert payload == {"id": 42, "command": "frame.duplicate", "params": {"frame": 3}}

    def test_params_default_to_an_object(self):
        assert json.loads(encode_request(1, "sprite.info"))["params"] == {}

    def test_compact(self):
        assert " " not in encode_request(1, "a", {"b": 1})


class TestDecode:
    def test_object(self):
        assert decode_message('{"id":1,"ok":true}') == {"id": 1, "ok": True}

    def test_bytes(self):
        assert decode_message(b'{"id":1}') == {"id": 1}

    @pytest.mark.parametrize("raw", ["not json", "", "{unclosed"])
    def test_malformed_json(self, raw):
        with pytest.raises(BridgeError) as excinfo:
            decode_message(raw)
        assert excinfo.value.code is ErrorCode.PROTOCOL_ERROR

    @pytest.mark.parametrize("raw", ["[1,2,3]", '"a string"', "42", "null"])
    def test_non_object_payloads_are_rejected(self, raw):
        with pytest.raises(BridgeError) as excinfo:
            decode_message(raw)
        assert excinfo.value.code is ErrorCode.PROTOCOL_ERROR

    def test_invalid_utf8(self):
        with pytest.raises(BridgeError) as excinfo:
            decode_message(b"\xff\xfe")
        assert excinfo.value.code is ErrorCode.PROTOCOL_ERROR


class TestErrorMapping:
    def test_known_code(self):
        error = error_from_response(
            {"ok": False, "error": {"code": "INVALID_FRAME", "message": "Frame 12 does not exist."}}
        )
        assert error.code is ErrorCode.INVALID_FRAME
        assert "Frame 12" in error.message

    def test_unknown_code_becomes_a_lua_error(self):
        # A handler failing in an unexpected way must still yield a usable error.
        error = error_from_response({"ok": False, "error": {"code": "WAT", "message": "boom"}})
        assert error.code is ErrorCode.LUA_ERROR
        assert error.message == "boom"

    @pytest.mark.parametrize("payload", [{"ok": False}, {"ok": False, "error": "oops"}])
    def test_malformed_error_body(self, payload):
        assert error_from_response(payload).code is ErrorCode.PROTOCOL_ERROR

    def test_missing_message_still_reads_sensibly(self):
        error = error_from_response({"ok": False, "error": {"code": "TIMEOUT"}})
        assert error.code is ErrorCode.TIMEOUT
        assert error.message

    def test_str_leads_with_the_code(self):
        # This is what the agent sees when a tool call fails.
        assert str(BridgeError(ErrorCode.INVALID_FRAME, "nope")) == "INVALID_FRAME: nope"


def test_error_codes_match_the_lua_side():
    """The two enums must not drift apart."""
    lua = (
        __import__("pathlib").Path("extension/aseprite-mcp/protocol.lua").read_text(encoding="utf-8")
    )
    body = lua.split("M.ERROR = {", 1)[1].split("}", 1)[0]
    lua_codes = {
        line.split("=", 1)[0].strip() for line in body.splitlines() if "=" in line
    }
    python_codes = {code.value for code in ErrorCode}

    # The Lua side never raises these: they are produced by the server itself.
    server_only = {"ASEPRITE_NOT_CONNECTED", "TIMEOUT", "UNAUTHORIZED", "INSTANCE_REQUIRED",
                   "EXTENSION_OUTDATED"}
    assert lua_codes <= python_codes, f"Lua has codes Python lacks: {lua_codes - python_codes}"
    assert python_codes - lua_codes == server_only
