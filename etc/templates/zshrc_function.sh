# Zsh / Bash Wrapper Function for Selvedge Makefile
# Copy the following block and paste it into your ~/.zshrc (or ~/.bashrc)

# Define the location of your Selvedge deployment project
export SELVEDGE_DIR="/opt/selvedge"

selvedge() {
    if [ ! -d "$SELVEDGE_DIR" ]; then
        echo "Error: Selvedge project directory '$SELVEDGE_DIR' not found." >&2
        return 1
    fi
    # Execute make in a subshell to avoid changing the active shell's directory
    (cd "$SELVEDGE_DIR" && make "$@")
}

# Zsh Autocomplete Integration
# Dynamically parses targets from the Makefile to support tab-completion
if [ -n "$ZSH_VERSION" ]; then
    _selvedge() {
        local -a targets
        if [ -d "$SELVEDGE_DIR" ] && [ -f "$SELVEDGE_DIR/Makefile" ]; then
            # Extract targets that have help descriptions (contain ##) or are common targets
            targets=($(awk -F: '/^[a-zA-Z0-9_ -]+:.*##/ {print $1}' "$SELVEDGE_DIR/Makefile"))

            # Also read included makefiles in make.d/
            for mk_file in "$SELVEDGE_DIR"/make.d/*.mk; do
                if [ -f "$mk_file" ]; then
                    targets+=($(awk -F: '/^[a-zA-Z0-9_ -]+:.*##/ {print $1}' "$mk_file"))
                fi
            done

            _describe 'targets' targets
        fi
    }
    compdef _selvedge selvedge
fi
