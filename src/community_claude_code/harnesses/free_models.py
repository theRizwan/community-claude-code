"""Free public-model aliases backed by the local OpenCode shim."""

SHIM_DEFAULT_PORT = 4097

FREE_MODELS: tuple[str, ...] = (
    "opencode/glm-5.3-flash-free",
    "opencode/deepseek-v4.1-flash-free",
    "opencode/mimo-v2.6-flash-free",
    "opencode/flint-40b-free",
    "opencode/big-pickle",
    "opencode/iceman-free",
    "opencode/minimax-m3.1-flash-free",
    "opencode/longcat-2.5-free",
    "opencode/nemotron-3.5-super-vl-free",
    "opencode/nemotron-3.5-lightning-free",
    "opencode/beam-free",
    "opencode/inkling-2-small-free",
)

DEFAULT_MODEL_BACKENDS: dict[str, str] = {
    "fable-5-free": "opencode/glm-5.3-flash-free",
    "opus-4.5-free": "opencode/deepseek-v4.1-flash-free",
    "sonnet-4.5-free": "opencode/mimo-v2.6-flash-free",
    "haiku-4.5-free": "opencode/flint-40b-free",
    "opus-5.5": "opencode/deepseek-v4.1-flash-free",
}


def _split_ref(value: str) -> tuple[str, str]:
    provider, separator, model = value.strip().partition("/")
    if not separator or not provider or not model:
        raise ValueError(f"Expected provider/model, got {value!r}")
    return provider, model


def build_default_chains() -> dict[str, list[tuple[str, str]]]:
    """Return the public-model to free-backend chain mapping."""

    chains: dict[str, list[tuple[str, str]]] = {}
    for public, primary in DEFAULT_MODEL_BACKENDS.items():
        ordered = [primary, *(model for model in FREE_MODELS if model != primary)]
        chains[public] = [_split_ref(model) for model in ordered]
    return chains
