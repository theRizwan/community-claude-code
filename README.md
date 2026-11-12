# 

<img src="assets/community-claude-code-wordmark-dark.svg" alt="Community Claude Code" width="791" />![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-2e7d32.svg?style=for-the-badge)![Python 3.14](https://img.shields.io/badge/python-3.14-3776ab.svg?style=for-the-badge&logo=python&logoColor=white)![Package Manager: uv](assets/package-manager-uv.svg)![Testing: Pytest](https://img.shields.io/badge/Testing-Pytest-ad1457.svg?style=for-the-badge)![Type Checker: Ty](https://img.shields.io/badge/Type%20Checker-ty-fdd835.svg?style=for-the-badge)![Formatter: Ruff](https://img.shields.io/badge/Formatter-ruff-bf4b00.svg?style=for-the-badge)![Logging: Loguru](https://img.shields.io/badge/logging-loguru-00695c.svg?style=for-the-badge)[Quick Start](#quick-start) · [Providers](#choose-a-provider) · [Clients](#connect-your-client) · [Integrations](#optional-integrations) · [Manage](#manage-your-installation)

*Independent open-source project. Not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.*

## Features

- Route any supported harness to models from any supported provider.
- Preserved native streaming, tool use, and interleaved thinking for maximum performance.
  - For Claude Code, All Models are free to use. [Fable](https://www.anthropic.com/claude/fable), [Opus](https://www.anthropic.com/claude/opus), [Sonnet](https://www.anthropic.com/claude/sonnet), and [Haiku](https://www.anthropic.com/claude/haiku) to supported models.
  - CCC follows provider TOS and removes integrations if they stop being allowed.
- Use through the terminal, desktop apps ([Codex App](https://learn.chatgpt.com/docs/app), [Claude Desktop](https://claude.ai/download), and [DeepSeek Desktop](https://github.com/deepseek-ai/deepseek-harness)), IDE extensions ([VS Code](https://code.visualstudio.com/) and [JetBrains](https://www.jetbrains.com/)), your phone ([Discord](https://discord.com/) and [Telegram](https://telegram.org/)), or your browser through native Code sessions.
  - Voice notes supported for Discord and Telegram using local [Whisper](https://github.com/openai/whisper) or [NVIDIA NIM](https://docs.nvidia.com/nim/speech/latest/asr/deploy-asr-models/whisper.html).
- Up to 90% lower token usage using [RTK](https://github.com/rtk-ai/rtk) and [Headroom](https://github.com/headroomlabs-ai/headroom).
- State-of-the-art reliability features so you can keep coding through provider outages:
  - Automatic retries.
  - Configurable rate limits.
  - Configurable concurrency control.
  - Automatic model/provider fallback.
  - Automatic multi-API key fallback.

Freely available to use Just Run Happy Coding!!!!

<img src="assets/pic.png" alt="Claude Code running with Community Claude Code" width="700" />*Claude Code running with CCC.*

<img src="assets/browser-code-session.png" alt="Native Codex browser session in CCC, showing model controls and a repository exploration" width="700" />*A native Codex session in CCC's browser UI.*

## Quick Start

### 1. Install

macOS/Linux:

```bash
curl -fsSL "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install.sh" | sh
```

Windows PowerShell:

```powershell
irm "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install.ps1" | iex
```

When prompted, choose at least one coding agent and optionally enable [RTK](https://github.com/rtk-ai/rtk) + [Headroom](https://github.com/headroomlabs-ai/headroom) token optimization for supported agents.

### 2. Start CCC

#### Windows

Open **Community Claude Code** from your desktop or Start menu.

#### macOS

Open **Community Claude Code** from your desktop or Applications folder.

#### Linux

Run:

```bash
ccc-server
```

CCC opens the Admin UI after starting. On Windows and macOS, use the tray or menu-bar icon to open Admin, restart, or quit. When using `ccc-server`, keep its terminal open.

### 3. Configure NVIDIA NIM

1. Create an API key at [build.nvidia.com/settings/api-keys](https://build.nvidia.com/settings/api-keys).
2. Open the Admin UI URL from the server log.
3. Open NVIDIA NIM in **Providers**, click **Add key**, paste the key, and click **Save**.
4. Leave `MODEL` on the default `nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b`, or search the model dropdown and select another model.
5. Click **Apply** to save your model selection.

To protect the local proxy with a bearer token, enable **Proxy Authentication**in Admin.

![](./README.assets/image.png)\### 4. Run Your Coding Agent

Claude Code:

```bash
ccc-claude
```

Codex:

```bash
ccc-codex
```

Pi:

```bash
ccc-pi
```

OpenCode 2:

```bash
ccc-opencode
```

Cline:

```bash
ccc-cline
```

Hermes:

```bash
ccc-hermes
```

DeepSeek Harness Web:

```bash
ccc-dsh
```

Grok Build:

```bash
ccc-grok
```

Muse Code:

```bash
ccc-muse
```

Aider:

```bash
ccc-aider
```

Antigravity CLI (connect on the Integrations page first):

```bash
ccc-agy
```

Other Chat Completions clients can use CCC's server URL followed by `/v1` as their OpenAI-compatible base URL (default `http://127.0.0.1:8082/v1`). Select an CCC model such as `gemini/models/gemini-3.5-flash-lite`. If Proxy Authentication is enabled, use its token as the client's API key. Both streaming and JSON replies are supported.

*Select an CCC model from Claude Code's native* `/model` *picker.*

## Choose A Provider

1. Open a provider link below for its key, models, or setup instructions.
2. In the Admin UI, configure the listed setting. For OpenAI / ChatGPT subscription access, use **Providers → OAuth providers** instead.
3. Search the `MODEL` dropdown and select a model. If the provider cannot list models, enter `<provider-id>/<exact-provider-model-id>` manually.
4. Click **Apply**.

Optional: add an ordered **Fallback Models** list under **Model Config**. It applies to every connected client. A failed request may reach and consume usage from more than one provider before succeeding.

Provider modals support numbered API keys. Use **Add key**, remove rows, or drag their handles to reorder them. CCC uses key 1.

For another API endpoint, open **Providers → Custom providers → Add provider**. Enter its API base URL, optional keys, and API format. Leave **Model IDs** empty to discover models automatically, or enter one upstream model ID per line. Save, then select a model in **Model Config**.

<details>
<summary>Provider catalog</summary>

ProviderAdmin UI settingExample MODELNVIDIA NIMNVIDIA_NIM_API_KEYnvidia_nim/nvidia/nemotron-3-ultra-550b-a55bOpenRouterOPENROUTER_API_KEYopen_router/openrouter/freeGroqGROQ_API_KEYgroq/llama-3.3-70b-versatileClinePassCLINE_API_KEYcline_pass/cline-pass/kimi-k3OpenAI / ChatGPTConnect ChatGPT in the Admin UIopenai/OpenAI APIOPENAI_API_KEYopenai_api/gpt-5.6-solGitHub CopilotConnect GitHub Copilot in the Admin UIgithub_copilot/xAI (Grok)XAI_API_KEYxai/grok-4.5Alibaba CloudALIBABA_CLOUD_API_KEYalibaba_cloud/QwenCloud Token PlanQWENCLOUD_API_KEYqwencloud/qwen3.7-plusQwenCloud Coding PlanQWENCLOUD_CODING_API_KEYqwencloud_coding/qwen3.7-plusTogether AITOGETHER_API_KEYtogether/zai-org/GLM-5.2DeepInfraDEEPINFRA_API_KEYdeepinfra/deepseek-ai/DeepSeek-V4-FlashSiliconFlowSILICONFLOW_API_KEYsiliconflow/Qwen/Qwen3-32BNebius Token FactoryNEBIUS_API_KEYnebius/Qwen/Qwen3-30B-A3BChutesCHUTES_API_KEYchutes/Qwen/Qwen3-32B-TEEFeatherless AIFEATHERLESS_API_KEYfeatherless/Qwen/Qwen3-32BAgnes AIAGNES_API_KEYagnes/agnes-2.0-flashZenMuxZENMUX_API_KEYzenmux/deepseek/deepseek-v4-flash-freeW&B InferenceWANDB_API_KEYwandb/openai/gpt-oss-20bAnthropicANTHROPIC_API_KEYanthropic/Azure OpenAIAZURE_OPENAI_API_KEY and AZURE_OPENAI_BASE_URLazure_openai/Google AI Studio (Gemini)GEMINI_API_KEYgemini/models/gemini-3.1-flash-liteGoogle Vertex AIVERTEX_PROJECT_ID + ADCvertex/google/gemini-3.5-flashDeepSeekDEEPSEEK_API_KEYdeepseek/deepseek-chatMistral La PlateformeMISTRAL_API_KEYmistral/devstral-small-latestMistral CodestralCODESTRAL_API_KEYmistral_codestral/codestral-latestOpenCode ZenOPENCODE_API_KEYopencode_zen/gpt-5.3-codexOpenCode GoOPENCODE_API_KEYopencode_go/minimax-m2.7Vercel AI GatewayAI_GATEWAY_API_KEYvercel/openai/gpt-5.5Amazon BedrockAWS_BEARER_TOKEN_BEDROCKbedrock/openai.gpt-oss-120bHugging Face Inference ProvidersHUGGINGFACE_API_KEYhuggingface/Qwen/Qwen3-Coder-480B-A35B-Instruct:fastestCohereCOHERE_API_KEYcohere/command-a-plus-05-2026WaferWAFER_API_KEYwafer/DeepSeek-V4-ProKimi APIKIMI_API_KEYkimi/kimi-k2.5Kimi CodeKIMI_CODE_API_KEYkimi_code/k3MiniMaxMINIMAX_API_KEYminimax/MiniMax-M3Cerebras InferenceCEREBRAS_API_KEYcerebras/gpt-oss-120bSambaNovaSAMBANOVA_API_KEYsambanova/Meta-Llama-3.3-70B-InstructKilo.aiKILO_API_KEYkilo/kilo-auto/freeFireworks AIFIREWORKS_API_KEYfireworks/accounts/fireworks/models/llama-v3p3-70b-instructNovita AINOVITA_API_KEYnovita/deepseek/deepseek-v4-flash-0731Cloudflare Workers AICLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_IDcloudflare/@cf/moonshotai/kimi-k2.6Z.ai Coding PlanZAI_API_KEYzai/glm-5.2Z.ai API (pay as you go)ZAI_API_KEYzai_api/glm-4.7-flashTokenRouterTOKENROUTER_API_KEYtokenrouter/moonshotai/kimi-k3-freeNaraRouteNARAROUTE_API_KEYnararoute/kimi-k3-freePoolside AIPOOLSIDE_API_KEYpoolside/poolside/laguna-s-2.1LLM7.ioLLM7_API_KEYllm7/defaultScalewaySCW_SECRET_KEYscaleway/deepseek/deepseek-v4-flashLightning AILIGHTNING_API_KEYlightning/lightning-ai/Qwen3.8-27BExperiential LabsEXPLABS_API_KEYexperiential/union-alphaCheaper InferenceCHEAPER_INFERENCE_API_KEYcheaperinference/gpt-5.4-miniOrcaRouterORCAROUTER_API_KEYorcarouter/deepseek/deepseek-v4-flash-freeAtlas CloudATLASCLOUD_API_KEYatlascloud/deepseek-ai/deepseek-v4-flashxKiroXKIRO_API_KEYxkiro/qwen/qwen3.7-flash:freeOpperOPPER_API_KEYopper/claude-sonnet-4-6Ollama CloudOLLAMA_API_KEYollama_cloud/qwen3-coder:480bLM StudioLM_STUDIO_BASE_URLlmstudio/llama.cppLLAMACPP_BASE_URLllamacpp/OllamaOLLAMA_BASE_URLollama/

</details>

<details>
<summary>Provider-specific setup</summary>

OpenAI / ChatGPT uses your ChatGPT subscription rather than an API key. Connect from Providers → OAuth providers → OpenAI / ChatGPT → Connect in the Admin UI and finish signing in through your browser. Restart an already-running agent after connecting.Anthropic uses a separately billed API key. Add it under Providers → Cloud providers → Anthropic → Configure, then choose a discovered model. Multi-workspace keys also require ANTHROPIC_WORKSPACE_ID.OpenAI API uses a separate Platform API key. Enter it under Providers → Cloud providers → OpenAI API → Configure. The model list may include IDs that cannot handle coding requests. Choose a text-generation model.GitHub Copilot uses your signed-in GitHub account and subscription. Install Copilot CLI 1.0.83on PATH, then choose Providers → OAuth providers → GitHub Copilot → Connect. Finish signing in, then select a github_copilot/ from the model picker. Available models and quotas depend on your subscription and organization policies. Restart an already-running agent after connecting.Azure OpenAI uses the deployment names from your resource. Set AZURE_OPENAI_BASE_URL to its complete v1 endpoint, such as https://YOUR-RESOURCE-NAME.openai.azure.com/openai/v1/, and select a deployment that supports Chat Completions. Enter the deployment name as a custom model slug if it does not appear in the model dropdown.Mistral Codestral uses a separate key from Mistral La Plateforme.Kimi Code subscription keys use kimi_code/. Kimi API credit keys use kimi/. Kimi Code plans are for personal interactive coding-agent use under Kimi's community guidelines.Alibaba Cloud uses a Model Studio pay-as-you-go key and defaults to Singapore. For another region or workspace, set ALIBABA_CLOUD_BASE_URL to its OpenAI-compatible endpointending in /compatible-mode/v1. The key and endpoint must use the same region.QwenCloud Coding Plan keys use qwencloud_coding/. QwenCloud Token Plan keys use qwencloud/. The keys and endpoints are not interchangeable. Coding Plan is for local, personal, interactive coding-agent use under the Coding Plan terms.OpenCode Zen and OpenCode Go share OPENCODE_API_KEY but use the explicit opencode_zen/ and opencode_go/ model prefixes.For Amazon Bedrock, set BEDROCK_BASE_URL to the URL for the same region as the API key and select one of the listed models.Vertex AI uses Google Application Default Credentials instead of an API key. Locally, run gcloud auth application-default login once. Service-account files and attached service accounts also work. Set VERTEX_PROJECT_ID, and optionally change VERTEX_LOCATION from its global default.Cloudflare requires both its API token and account ID.For Ollama Cloud, use the exact model IDs shown in the model picker. Local Ollama uses the separate ollama/ prefix.Prefer tool-capable models for coding agents. Local models also need enough context for the agent's system prompt and tool definitions.

</details>

<details>
<summary>Local provider setup</summary>

CCC automatically discovers models from running local servers at startup. If you start a server later, click Refresh models in Admin to add its models to the picker.LM StudioStart LM Studio's local server, load a tool-capable model, and use the model identifier shown by LM Studio with the lmstudio/ prefix. The default URL is http://localhost:1234/v1.llama.cppStart llama-server with its OpenAI-compatible Chat Completions API and enough context for the model. Use the local model ID with the llamacpp/ prefix. LLAMACPP_BASE_URL defaults to http://localhost:8080/v1.Ollamaollama pull llama3.1 ollama serveUse the tag shown by ollama list with the ollama/ prefix. OLLAMA_BASE_URL defaults to http://localhost:11434.Provider cards show the checked endpoint and response time, with a useful message when a local server is unavailable. After starting the server or correcting its settings, click Test to refresh its models.

</details>

<details>
<summary>Optional model-tier routing</summary>

MODEL is the fallback for every request. Select a model for MODEL_FABLE, MODEL_OPUS, MODEL_SONNET, or MODEL_HAIKU to override an individual Claude Code tier. Select None to use MODEL.In Admin UI → Model Config, add Fallback Models in the order CCC should try them if the selected model fails. Each fallback has its own reasoning effort: Inherit, Off, From client, Low, Medium, High, X-High, or Max.Choose a model, effort, and API key number in the bottom row, then click +. Key 1, Key 2, and so on refer to the current numbered keys in that provider's settings. Edit the selections in place, drag the handle to change the order, or click the red trash button to remove a fallback.Inherit keeps the original request's resolved reasoning setting. From client uses the effort or token budget sent by your coding agent, bypassing the global or tier setting. You can select the same model with another key number.

</details>

<details>
<summary>Reasoning control</summary>

Open Admin UI → Model Config → Model Routing and choose an effort beside each model. Default Effort starts at From client. Fable, Opus, Sonnet, and Haiku start at Inherit.SelectionBehaviorFrom clientUse the effort sent by your coding agent. If none is sent, keep the provider default.OffRequest reasoning to be disabled.Low, Medium, High, X-High, or MaxOverride the client with the selected reasoning level.InheritTier overrides use Default Effort. Fallbacks keep the original request's resolved effort.

</details>

## 

## Optional Integrations

Configure integrations from **Admin UI → Messaging**, then click **Apply**.

<details>
<summary>Discord bot</summary>

Create a bot in the Discord Developer Portal.Enable Message Content Intent and invite it with read, send, message-history, and Manage Messages permissions so /clear can remove user prompts.Set Messaging Platform to discord.Enter Discord Bot Token, Allowed Discord Channels, and an absolute Allowed Directory.Apply the settings and restart the server if requested.

</details>

<details>
<summary>Telegram bot</summary>

Create a bot with @BotFather.Get your numeric user ID from @userinfobot. In groups, grant the bot permission to delete messages.Set Messaging Platform to telegram.Enter Telegram Bot Token, Allowed Telegram User ID, and an absolute Allowed Directory.Apply the settings and restart the server if requested.

</details>

### Messaging commands

| Usage | Behavior |
| --- | --- |
| `/stats` | Show session state. |
| Standalone `/stop` | Cancel all work. |
| Reply with `/stop` | Cancel only the selected request while other queued requests continue. |
| Standalone `/clear` | Clear all CCC conversations and their messages in this chat. |
| Reply with `/clear` | Delete the selected message and the chain of replies to it. Keep other conversations. |

<details>
<summary>Voice notes</summary>

NVIDIA NIM transcription support is included in every installation. In Admin UI → Messaging → Voice, enable voice notes, select nvidia_nim, and choose a supported model. Configure your NVIDIA NIM API key on the Providers page.For local Whisper on CPU or CUDA, re-run the installer with the local voice option:macOS/Linux:Local Whisper on CPU or CUDA:curl -fsSL "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install.sh" | sh -s -- --voice-localLocal Whisper with CUDA 13.0:curl -fsSL "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install.sh" | sh -s -- --voice-local --torch-backend cu130Windows PowerShell:Local Whisper on CPU or CUDA:& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install.ps1"))) -VoiceLocalLocal Whisper with CUDA 13.0:& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install.ps1"))) -VoiceLocal -TorchBackend cu130After installing local support, restart ccc-server. In Admin UI → Messaging → Voice, enable voice notes, select cpu or cuda, and choose the Whisper model. Local gated models need HUGGINGFACE_API_KEY.

</details>

## Manage Your Installation

Run `ccc-server --version` to check the installed version without starting CCC.

### Update

Stop all running CCC commands, then run:

```sh
ccc-update
```

The update installs the checked stable CCC release with its matching installer.

If `ccc-update` is unavailable or fails, try running the [install command](#install) again.

To reinstall CCC or change optional components while already up to date, run the [installer](#install) directly.

For local voice support, include `--voice-local` (macOS/Linux) or `-VoiceLocal` (Windows), plus your `--torch-backend` or `-TorchBackend` option if used.

### Muse Code on native Windows

To install or update only Muse Code:

```powershell
irm "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/install-muse.ps1" | iex
```

To remove the Muse Code copy installed by CCC, keeping its data:

```powershell
irm "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/uninstall-muse.ps1" | iex
```

Uninstalling CCC leaves Muse Code installed.

### Uninstall

Stop every running CCC command and quit connected desktop/editor apps before uninstalling.

**Removes**

- Community Claude Code, including its desktop launcher and commands
- `~/.ccc/`

**Keeps**

- uv and Python
- Your coding agents, RTK, and Headroom

macOS/Linux:

```bash
curl -fsSL "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/uninstall.sh" | sh
```

Windows PowerShell:

```powershell
irm "https://raw.githubusercontent.com/theRizwan/community-claude-code/main/scripts/uninstall.ps1" | iex
```

## Project Links

For a problem after installation, run the command below and paste its output into your bug report.

```bash
ccc-doctor
```

- [Report bugs or request features](https://github.com/theRizwan/community-claude-code/issues)
- [Contributing guide](CONTRIBUTING.md)

## License

GNU Affero General Public License version 3 only (`AGPL-3.0-only`). See [LICENSE](LICENSE) for details.