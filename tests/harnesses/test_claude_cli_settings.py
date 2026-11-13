import json

import pytest

from community_claude_code.harnesses import claude_cli_settings


def test_configure_merges_gateway_and_preserves_settings(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(
        json.dumps(
            {
                "env": {
                    "ANTHROPIC_BASE_URL": "http://127.0.0.1:9000/v1",
                    "UNRELATED": "keep",
                },
                "theme": "dark",
            }
        ),
        encoding="utf-8",
    )

    assert claude_cli_settings.configure(path, "http://127.0.0.1:9000", "token")

    document = json.loads(path.read_text(encoding="utf-8"))
    assert document["theme"] == "dark"
    assert document["env"]["UNRELATED"] == "keep"
    assert document["env"]["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:9000"
    assert document["env"]["ANTHROPIC_AUTH_TOKEN"] == "token"
    assert document["env"]["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] == "1"
    assert not claude_cli_settings.configure(path, "http://127.0.0.1:9000", "token")


def test_configure_creates_settings_file(tmp_path):
    path = tmp_path / "nested" / "settings.json"

    assert claude_cli_settings.configure(path, "http://127.0.0.1:9000", "token")

    assert (
        json.loads(path.read_text(encoding="utf-8"))["env"]["ANTHROPIC_BASE_URL"]
        == "http://127.0.0.1:9000"
    )


def test_configure_rejects_non_object_environment(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"env": ["invalid"]}), encoding="utf-8")

    with pytest.raises(ValueError):
        claude_cli_settings.configure(path, "http://127.0.0.1:9000", "token")
