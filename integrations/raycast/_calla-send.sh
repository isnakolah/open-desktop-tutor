# Shared by the Calla Raycast commands. Not a command itself: Raycast only
# lists files carrying the @raycast metadata header, so this stays hidden.
#
# Everything goes to one session, which is what makes a lesson a conversation
# rather than a series of unrelated questions — Calla keeps what it already
# told you and re-checks the screen before answering.

CALLA_GATEWAY_SSH="${CALLA_GATEWAY_SSH:-isnakolah@nomonhomelab}"
# A control socket has to fit in 104 bytes, so keep this path short.
CALLA_CONTROL="/tmp/calla-raycast.sock"
CALLA_SESSION="${CALLA_SESSION:-calla-raycast}"
# The Gateway defaults to "high" thinking, which costs about three minutes a
# step here and buys nothing: finding a labelled control in a screenshot is
# recognition, not reasoning. Measured on this setup — high 204s, low 64s,
# minimal 40s — and "minimal" started drifting off the icon, so "low" is the
# point where it stops being slow without becoming wrong.
CALLA_THINKING="${CALLA_THINKING:-low}"

calla_send() {
  local message="$1"
  local options=(
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o ControlMaster=auto
    -o "ControlPath=$CALLA_CONTROL"
    -o ControlPersist=8h
  )
  local quoted
  quoted=$(printf '%s' "$message" | sed "s/'/'\\\\''/g")

  local remote="export PATH=\$HOME/.npm-global/bin:\$PATH;
nohup openclaw agent --session-id $CALLA_SESSION --thinking $CALLA_THINKING -m '$quoted' \
  > /tmp/calla-raycast-last.txt 2>&1 &
echo started"

  local output
  if ! output=$(ssh "${options[@]}" "$CALLA_GATEWAY_SSH" "$remote" 2>&1); then
    if [[ "$output" == *"login.tailscale.com"* ]]; then
      local url
      url=$(printf '%s' "$output" | grep -o 'https://login.tailscale.com/[^ ]*' | head -1)
      echo "Tailscale needs one approval: $url"
      return 1
    fi
    echo "Could not reach Calla's Gateway: ${output##*$'\n'}"
    return 1
  fi
  return 0
}
