#!/bin/sh
set -eu

PACKAGE_NAME="community-claude-code"
CCC_HOME_DIRNAME=".ccc"
CCC_MACOS_BUNDLE_ID="io.github.theRizwan.community-claude-code"
CCC_MACOS_OWNER_FILE=".community-claude-code-owner"
# Include retired entry points so older installations are fully stopped and removed.
CCC_COMMANDS="ccc-desktop ccc-server ccc-claude ccc-codex ccc-pi ccc-opencode ccc-cline ccc-hermes ccc-dsh ccc-grok ccc-muse ccc-aider ccc-agy ccc-doctor ccc-update ccc-init community-claude-code"

dry_run=0
keep_integrations=0
uv_tool_bin=""

show_usage() {
    cat <<'USAGE'
Usage: uninstall.sh [options]

Removes the Community Claude Code uv tool and deletes ~/.ccc/ after removal is verified.
Does not remove uv, Claude Code, Codex, Pi, OpenCode, Cline, Hermes Agent, DeepSeek Harness, Grok Build, Muse Code, Aider, Antigravity CLI, the uv-managed Python runtime, or shared PATH entries.

Options:
  --dry-run                Print commands without running them.
  --keep-integrations      Leave editor/app integrations unchanged.
  --help                   Show this help text.
USAGE
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$1"
}

quote_arg() {
    case "$1" in
        *[!A-Za-z0-9_./:@%+=,-]*|"")
            escaped=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
            printf '"%s"' "$escaped"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

print_command() {
    printf '+'
    for arg in "$@"; do
        printf ' '
        quote_arg "$arg"
    done
    printf '\n'
}

run() {
    print_command "$@"
    if [ "$dry_run" -eq 1 ]; then
        return 0
    fi

    if "$@"; then
        return 0
    else
        status=$?
    fi
    fail "Command failed with exit code $status: $1"
}

is_missing_uv_tool_error() {
    normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$normalized" in
        *"$PACKAGE_NAME"*"is not installed"*) return 0 ;;
        *) return 1 ;;
    esac
}

add_path_entry() {
    [ -n "$1" ] || return 0
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="$1:$PATH" ;;
    esac
}

add_known_uv_paths() {
    if [ -n "${XDG_BIN_HOME:-}" ]; then
        add_path_entry "$XDG_BIN_HOME"
    fi
    add_path_entry "$HOME/.local/bin"
    add_path_entry "$HOME/.cargo/bin"
    export PATH
    hash -r 2>/dev/null || true
}

ccc_process_ids() {
    command_name=$1

    if command -v pgrep >/dev/null 2>&1; then
        {
            pgrep -x "$command_name" 2>/dev/null || true
            pgrep -f "(^|/)${command_name}([[:space:]]|$)" 2>/dev/null || true
        } | sort -nu
        return 0
    fi

    ps -A -o pid= -o args= 2>/dev/null |
        awk -v command_name="$command_name" '
            BEGIN {
                pattern = "(^|/)" command_name "([[:space:]]|$)"
            }
            {
                process_id = $1
                sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
                if ($0 ~ pattern) {
                    print process_id
                }
            }
        ' || true
}

is_ccc_command_running() {
    [ -n "$(ccc_process_ids "$1")" ]
}

assert_no_ccc_processes_running() {
    running=""
    for command_name in $CCC_COMMANDS; do
        if is_ccc_command_running "$command_name"; then
            running="${running} ${command_name}"
        fi
    done

    if [ -n "$running" ]; then
        fail "Community Claude Code is still running (${running# }). Stop those processes, then rerun uninstall."
    fi
}

initialize_uv_context() {
    add_known_uv_paths

    if [ "$dry_run" -eq 1 ]; then
        print_command uv tool dir --bin
        return 0
    fi

    if ! command -v uv >/dev/null 2>&1; then
        fail "uv is required to remove the Community Claude Code tool. Install uv, then rerun this uninstaller; ~/.ccc was not deleted."
    fi

    print_command uv tool dir --bin
    if uv_tool_bin=$(uv tool dir --bin); then
        :
    else
        status=$?
        fail "Could not determine the uv tool bin directory (exit code $status); ~/.ccc was not deleted."
    fi
    [ -n "$uv_tool_bin" ] || fail "uv returned an empty tool bin directory; ~/.ccc was not deleted."
}

uninstall_community_claude_code() {
    print_command uv tool uninstall "$PACKAGE_NAME"
    if [ "$dry_run" -eq 1 ]; then
        return 0
    fi

    if output=$(uv tool uninstall "$PACKAGE_NAME" 2>&1); then
        if [ -n "$output" ]; then
            printf '%s\n' "$output"
        fi
        return 0
    else
        status=$?
    fi

    if is_missing_uv_tool_error "$output"; then
        printf 'Community Claude Code uv tool is already absent; verifying its entry points.\n'
        return 0
    fi
    if [ -n "$output" ]; then
        printf '%s\n' "$output" >&2
    fi
    fail "uv tool uninstall $PACKAGE_NAME failed with exit code $status; ~/.ccc was not deleted."
}

disconnect_integrations() {
    [ "$keep_integrations" -eq 0 ] || return 0
    if [ "$dry_run" -eq 1 ]; then
        print_command ccc-doctor --disconnect-integrations
        return 0
    fi
    doctor="$uv_tool_bin/ccc-doctor"
    if [ ! -x "$doctor" ]; then
        fail "CCC's integration cleanup command is unavailable. Update CCC first, or disconnect editor/app integrations manually and rerun with --keep-integrations. CCC data was not deleted."
    fi
    print_command "$doctor" --disconnect-integrations
    if "$doctor" --disconnect-integrations; then
        return 0
    fi
    fail "Editor/app integration cleanup failed. Correct the reported problem and retry. For older CCC versions, update first or disconnect manually and rerun with --keep-integrations. CCC and its data were not deleted."
}

verify_ccc_commands_removed() {
    if [ "$dry_run" -eq 1 ]; then
        printf '+ verify all Community Claude Code entry points are absent from the uv tool bin directory\n'
        return 0
    fi

    remaining=""
    for command_name in $CCC_COMMANDS ccc-update.cmd; do
        command_path="$uv_tool_bin/$command_name"
        if [ -e "$command_path" ] || [ -L "$command_path" ]; then
            remaining="${remaining} ${command_path}"
        fi
    done
    if [ -n "$remaining" ]; then
        fail "Community Claude Code entry points remain after uv uninstall:${remaining}; ~/.ccc was not deleted."
    fi
}

macos_app_is_ccc_owned() {
    app_dir=$1
    [ -d "$app_dir" ] && [ ! -L "$app_dir" ] || return 1
    for owner_file in "$app_dir/Contents/Resources/$CCC_MACOS_OWNER_FILE" "$app_dir/Contents/$CCC_MACOS_OWNER_FILE"; do
        if [ -f "$owner_file" ] && [ "$(cat "$owner_file")" = "$CCC_MACOS_BUNDLE_ID" ]; then
            return 0
        fi
    done
    return 1
}

remove_macos_desktop_app() {
    [ "$(uname -s)" = "Darwin" ] || return 0

    app_dir="$HOME/Applications/Community Claude Code.app"
    desktop_link="$HOME/Desktop/Community Claude Code.app"

    if ! macos_app_is_ccc_owned "$app_dir"; then
        if [ -e "$app_dir" ] || [ -L "$app_dir" ]; then
            printf 'An app not managed by Community Claude Code exists at %s; leaving it unchanged.\n' "$app_dir"
        fi
        if [ -e "$desktop_link" ] || [ -L "$desktop_link" ]; then
            printf 'The Community Claude Code desktop item cannot be verified; leaving it unchanged.\n'
        fi
        return 0
    fi

    if [ -L "$desktop_link" ]; then
        if [ "$(readlink "$desktop_link")" = "$app_dir" ]; then
            run rm -f "$desktop_link"
        else
            printf 'A non-CCC link exists at %s; leaving it unchanged.\n' "$desktop_link"
        fi
    elif [ -e "$desktop_link" ]; then
        printf 'A non-CCC item exists at %s; leaving it unchanged.\n' "$desktop_link"
    fi
    if [ -e "$app_dir" ]; then
        run rm -rf "$app_dir"
    fi
}

purge_ccc_home() {
    ccc_home="$HOME/$CCC_HOME_DIRNAME"
    if [ ! -e "$ccc_home" ]; then
        printf 'No CCC config directory at %s; skipping purge.\n' "$ccc_home"
        return 0
    fi

    run rm -rf "$ccc_home"
    if [ "$dry_run" -eq 0 ] && [ -e "$ccc_home" ]; then
        fail "CCC config directory still exists after deletion: $ccc_home"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                dry_run=1
                ;;
            --keep-integrations)
                keep_integrations=1
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                show_usage >&2
                fail "unknown option: $1"
                ;;
        esac
        shift
    done
}

parse_args "$@"
[ -n "${HOME:-}" ] || fail "HOME is not set; cannot locate Community Claude Code data."

step "Checking for running Community Claude Code processes"
assert_no_ccc_processes_running

step "Locating the uv-managed Community Claude Code installation"
initialize_uv_context

step "Disconnecting CCC editor/app integrations"
disconnect_integrations

step "Removing the Community Claude Code uv tool"
uninstall_community_claude_code

step "Verifying Community Claude Code entry points were removed"
verify_ccc_commands_removed

step "Removing the Community Claude Code desktop launcher"
remove_macos_desktop_app

step "Purging CCC config and data from ~/.ccc"
purge_ccc_home

if [ "$dry_run" -eq 1 ]; then
    printf '\nDry run complete. No changes were made.\n'
else
    printf '\nCommunity Claude Code has been removed and verified.\n'
    printf 'uv, Claude Code, Codex, Pi, OpenCode, Cline, Hermes Agent, DeepSeek Harness, Grok Build, Muse Code, Aider, the uv-managed Python runtime, and shared PATH entries were left installed.\n'
fi
