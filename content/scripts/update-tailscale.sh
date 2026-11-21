#!/bin/sh

set -eu

# Update (or pin) the Tailscale client on a JetKVM device that already has
# Tailscale installed via install-tailscale.sh.
#
# Unlike install-tailscale.sh this never wipes /userdata/tailscale state and
# never runs `tailscale up`: the device keeps its node identity and auth.
#
# Known-broken versions are recorded on the device in
# /userdata/tailscale-blocked-versions (one version per line) so the block
# survives across runs and across machines you run this script from.

BLOCKLIST_FILE="/userdata/tailscale-blocked-versions"

# Versions that are always refused, regardless of the on-device list.
# Add known-broken releases here (space separated), e.g. "1.90.0 1.90.1".
BUILTIN_BLOCKED=""

SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# All the code is wrapped in a main function that gets called at the
# bottom of the file, so that a truncated partial download doesn't end
# up executing half a script.
main() {

	REQUESTED_VERSION=""
	JETKVM_IP=""
	AUTO_YES=false
	FORCE=false
	CHECK_ONLY=false
	LIST_BLOCKED=false
	BLOCK_VERSIONS=""
	UNBLOCK_VERSIONS=""

	usage() {
		echo "Usage: $0 [options] <JETKVM_IP>"
		echo ""
		echo "Options:"
		echo "  -v, --version <VER>   Install this Tailscale version (default: current stable release)"
		echo "  -y, --yes             Automatically answer yes to confirmation prompt"
		echo "  -f, --force           Allow reinstalling the same version or downgrading"
		echo "  -n, --check           Only report installed vs. latest stable version; change nothing"
		echo "  -b, --block <VER>     Add VER to the device's blocklist (repeatable). Can be used alone"
		echo "  -u, --unblock <VER>   Remove VER from the device's blocklist (repeatable). Can be used alone"
		echo "  -l, --list-blocked    Show the blocklist on the device and exit"
		echo ""
		echo "Blocked versions are never installed, including when requested with --version."
		echo "The blocklist is stored on the device at $BLOCKLIST_FILE."
		echo ""
		echo "Examples:"
		echo "  $0 192.168.1.64                   # update to latest stable"
		echo "  $0 -n 192.168.1.64                # just check"
		echo "  $0 -v 1.88.1 -y 192.168.1.64      # pin a specific version"
		echo "  $0 -b 1.90.0 192.168.1.64         # block a broken release (then continue to update)"
	}

	# Parse command line arguments
	while [ $# -gt 0 ]; do
		case $1 in
		-v | --version)
			[ $# -ge 2 ] || { echo "ERROR: $1 requires a value"; exit 1; }
			REQUESTED_VERSION="$2"
			shift 2
			;;
		-y | --yes)
			AUTO_YES=true
			shift
			;;
		-f | --force)
			FORCE=true
			shift
			;;
		-n | --check)
			CHECK_ONLY=true
			shift
			;;
		-b | --block)
			[ $# -ge 2 ] || { echo "ERROR: $1 requires a value"; exit 1; }
			BLOCK_VERSIONS="$BLOCK_VERSIONS $2"
			shift 2
			;;
		-u | --unblock)
			[ $# -ge 2 ] || { echo "ERROR: $1 requires a value"; exit 1; }
			UNBLOCK_VERSIONS="$UNBLOCK_VERSIONS $2"
			shift 2
			;;
		-l | --list-blocked)
			LIST_BLOCKED=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			echo "ERROR: unknown option: $1"
			echo ""
			usage
			exit 1
			;;
		*)
			JETKVM_IP="$1"
			shift
			;;
		esac
	done

	if [ -z "$JETKVM_IP" ]; then
		echo "ERROR: JetKVM IP address is required"
		echo ""
		usage
		exit 1
	fi

	# Versions end up in remote shell commands and URLs: accept only X.Y.Z
	valid_version() {
		echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
	}
	for v in $REQUESTED_VERSION $BLOCK_VERSIONS $UNBLOCK_VERSIONS $BUILTIN_BLOCKED; do
		if ! valid_version "$v"; then
			echo "ERROR: invalid version '$v' (expected form: 1.88.1)"
			exit 1
		fi
	done

	# Returns success if $1 is strictly older than $2 (both X.Y.Z)
	version_lt() {
		[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$1" ]
	}

	rssh() {
		# shellcheck disable=SC2086
		ssh $SSH_OPTS -o BatchMode=yes root@"$JETKVM_IP" "$@"
	}

	echo "[1/8] Checking JetKVM device..."
	if ! ping -c 3 -W 5 "$JETKVM_IP" >/dev/null 2>&1; then
		echo "ERROR: JetKVM device at $JETKVM_IP is not reachable"
		exit 1
	fi
	if ! SSH_OUT=$(rssh 'echo ok' 2>&1); then
		echo "ERROR: SSH connection to root@$JETKVM_IP failed: $SSH_OUT"
		echo "       Ensure Developer Mode is enabled and your SSH key is added:"
		echo "       https://jetkvm.com/docs/advanced-usage/developing#developer-mode"
		exit 1
	fi
	echo "       Device is reachable, SSH access confirmed"

	# --- Blocklist maintenance -------------------------------------------------
	if [ -n "$BLOCK_VERSIONS" ]; then
		for v in $BLOCK_VERSIONS; do
			rssh "touch $BLOCKLIST_FILE && { grep -qxF '$v' $BLOCKLIST_FILE || echo '$v' >> $BLOCKLIST_FILE; } && sync"
			echo "       Blocked Tailscale $v on device"
		done
	fi
	if [ -n "$UNBLOCK_VERSIONS" ]; then
		for v in $UNBLOCK_VERSIONS; do
			rssh "[ ! -f $BLOCKLIST_FILE ] || { grep -vxF '$v' $BLOCKLIST_FILE > $BLOCKLIST_FILE.tmp; mv $BLOCKLIST_FILE.tmp $BLOCKLIST_FILE; sync; }"
			echo "       Unblocked Tailscale $v on device"
		done
	fi

	DEVICE_BLOCKED="$(rssh "cat $BLOCKLIST_FILE 2>/dev/null || true" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
	ALL_BLOCKED="$(printf '%s\n' $BUILTIN_BLOCKED $DEVICE_BLOCKED | sort -u | grep . || true)"

	is_blocked() {
		echo "$ALL_BLOCKED" | grep -qxF "$1"
	}

	if [ "$LIST_BLOCKED" = true ]; then
		echo "Blocked Tailscale versions:"
		if [ -n "$ALL_BLOCKED" ]; then
			echo "$ALL_BLOCKED" | sed 's/^/  /'
		else
			echo "  (none)"
		fi
		exit 0
	fi

	# A block/unblock-only invocation (no version, not a check) stops here.
	if [ -z "$REQUESTED_VERSION" ] && [ "$CHECK_ONLY" = false ] &&
		{ [ -n "$BLOCK_VERSIONS" ] || [ -n "$UNBLOCK_VERSIONS" ]; } && [ "$AUTO_YES" = false ]; then
		printf "Blocklist updated. Also check for a Tailscale update now? [y/N]: "
		if [ -t 0 ]; then read -r response; else read -r response </dev/tty; fi
		case "$response" in
		[yY] | [yY][eE][sS]) ;;
		*) exit 0 ;;
		esac
	fi

	# --- Is Tailscale installed? ----------------------------------------------
	echo "[2/8] Checking for an existing Tailscale installation..."
	INSTALLED_RAW="$(rssh 'tailscale version 2>/dev/null || /userdata/tailscale/tailscale version 2>/dev/null' || true)"
	INSTALLED_VERSION="$(echo "$INSTALLED_RAW" | head -n1 | sed -ne 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
	if [ -z "$INSTALLED_VERSION" ]; then
		echo "ERROR: Tailscale is not installed on $JETKVM_IP"
		echo "       Use install-tailscale.sh for a first-time installation."
		exit 1
	fi
	echo "       Installed version: $INSTALLED_VERSION"

	# --- Pick the target version ---------------------------------------------
	echo "[3/8] Determining target version..."
	STABLE="$(echo $(curl -fsSL "https://pkgs.tailscale.com/stable/?mode=json&os=linux") | sed -ne 's/.*"TarballsVersion":[ ]*"\([^"]*\)".*/\1/p')"
	if ! valid_version "$STABLE"; then
		echo "ERROR: could not determine latest stable Tailscale version (got '$STABLE')"
		exit 1
	fi
	echo "       Latest stable:     $STABLE"

	if [ "$CHECK_ONLY" = true ]; then
		if [ "$INSTALLED_VERSION" = "$STABLE" ]; then
			echo "       Up to date."
		elif is_blocked "$STABLE"; then
			echo "       Latest stable $STABLE is BLOCKED; not recommended for installation."
		else
			echo "       Update available: $INSTALLED_VERSION -> $STABLE"
		fi
		exit 0
	fi

	TARGET="${REQUESTED_VERSION:-$STABLE}"
	if is_blocked "$TARGET"; then
		echo "ERROR: Tailscale $TARGET is on the blocklist and will not be installed."
		if [ -z "$REQUESTED_VERSION" ]; then
			echo "       The latest stable release is blocked. Choose an older known-good version"
			echo "       with --version, or wait for a newer release."
		fi
		echo "       To allow it: $0 --unblock $TARGET $JETKVM_IP"
		exit 1
	fi
	if is_blocked "$INSTALLED_VERSION"; then
		echo "       WARNING: the installed version $INSTALLED_VERSION is on the blocklist."
	fi

	if [ "$TARGET" = "$INSTALLED_VERSION" ] && [ "$FORCE" = false ]; then
		echo "       Already running $TARGET, nothing to do (use --force to reinstall)."
		exit 0
	fi
	if version_lt "$TARGET" "$INSTALLED_VERSION" && [ "$FORCE" = false ]; then
		echo "ERROR: $TARGET is older than the installed $INSTALLED_VERSION (use --force to downgrade)"
		exit 1
	fi

	if [ "$AUTO_YES" = false ]; then
		echo ""
		echo "  JetKVM IP:          $JETKVM_IP"
		echo "  Installed version:  $INSTALLED_VERSION"
		echo "  Target version:     $TARGET"
		echo ""
		echo "  Note: node identity and login state are preserved; the device will be rebooted."
		echo ""
		printf "Continue? [y/N]: "
		if [ -t 0 ]; then read -r response; else read -r response </dev/tty; fi
		case "$response" in
		[yY] | [yY][eE][sS]) echo "" ;;
		*)
			echo "Update cancelled"
			exit 0
			;;
		esac
	fi

	# --- Download and verify --------------------------------------------------
	echo "[4/8] Downloading Tailscale $TARGET checksum..."
	HASH=$(curl -fsSL https://pkgs.tailscale.com/stable/tailscale_"${TARGET}"_arm.tgz.sha256)

	echo "[5/8] Downloading Tailscale $TARGET package..."
	TMP_FILE=$(mktemp -t tailscale.XXXXXX.tgz)
	trap 'rm -f "$TMP_FILE"' EXIT
	curl -fSL https://pkgs.tailscale.com/stable/tailscale_"${TARGET}"_arm.tgz -o "$TMP_FILE" >/dev/null 2>&1

	LOCAL_HASH=$(sha256sum "$TMP_FILE" | awk '{print $1}')
	if [ "$HASH" != "$LOCAL_HASH" ]; then
		echo "ERROR: Package verification failed!"
		echo "       Expected: $HASH"
		echo "       Got:      $LOCAL_HASH"
		exit 1
	fi
	echo "       Package verification successful"

	# --- Install --------------------------------------------------------------
	echo "[6/8] Transferring package and installing on JetKVM..."
	rssh "cat > /userdata/tailscale.tgz" <"$TMP_FILE"

	# Binaries may be in use by the running daemon, so replace them with mv
	# (atomic rename) rather than cp, which fails with "Text file busy".
	# On a reboot-interrupted SSH session the exit status is meaningless, so
	# success is verified by version afterwards.
	ssh $SSH_OPTS -o ServerAliveInterval=1 -o ServerAliveCountMax=1 \
		root@"$JETKVM_IP" \
		"export TAILSCALE_VERSION=$TARGET; ash -s" 2>/dev/null <<'EOF' || true
  set -e
  cd /userdata

  echo "       Extracting package..."
  tar xf ./tailscale.tgz
  NEW="./tailscale_${TAILSCALE_VERSION}_arm"
  [ -x "$NEW/tailscale" ] && [ -x "$NEW/tailscaled" ] || { echo "ERROR: bad package layout"; exit 1; }

  mkdir -p ./tailscale
  for f in "$NEW"/*; do
    mv -f "$f" "./tailscale/.new.$(basename "$f")"
    mv -f "./tailscale/.new.$(basename "$f")" "./tailscale/$(basename "$f")"
  done
  rm -rf "$NEW" ./tailscale.tgz

  echo "       Re-applying JetKVM configuration..."
  cd ./tailscale
  ./tailscale configure jetkvm 2>&1 >/dev/null

  sync
  echo "       Rebooting JetKVM device..."
  ( sleep 1; reboot ) &
  exec tail -f /dev/null
EOF

	echo "[7/8] Waiting for JetKVM to reboot and come back online..."
	i=1
	NEW_VERSION=""
	while [ "$i" -le 120 ]; do
		echo "       Checking device status... ($i/120s)"
		RAW="$(ssh -q -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			root@"$JETKVM_IP" 'tailscale version' 2>/dev/null || true)"
		NEW_VERSION="$(echo "$RAW" | head -n1 | sed -ne 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
		[ -n "$NEW_VERSION" ] && break
		i=$((i + 1))
		sleep 1
	done
	if [ -z "$NEW_VERSION" ]; then
		echo "ERROR: Timeout - JetKVM did not come back online within 2 minutes"
		echo "       Please check the device status manually"
		exit 1
	fi

	echo "[8/8] Verifying update..."
	if [ "$NEW_VERSION" != "$TARGET" ]; then
		echo "ERROR: expected Tailscale $TARGET but device reports $NEW_VERSION"
		exit 1
	fi
	echo "       Tailscale now at $NEW_VERSION"
	rssh 'tailscale status 2>&1 | head -n 5' || true
	echo ""
	echo "SUCCESS: Tailscale updated from $INSTALLED_VERSION to $NEW_VERSION"
}

main "$@"
