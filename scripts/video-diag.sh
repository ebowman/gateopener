#!/usr/bin/env bash
#
# video-diag.sh -- paste-able macOS diagnostic capture for GateOpener door
# video failures.
#
# This script is self-contained: it does not source any file from the
# GateOpener repo and does not rely on the repo being present at all. It is
# meant to be pasted directly into Terminal on a Mac that has only the
# installed GateOpener.app (no repo, no Xcode, no Homebrew), so it uses only
# tools that ship with a stock macOS install: bash, log, sw_vers, defaults,
# PlistBuddy, ifconfig, route, scutil, dig (best-effort), curl,
# socketfilterfw, pgrep, ps.
#
# Usage (operator instructions are also printed as the first section below):
#   1. Quit and relaunch GateOpener.
#   2. Choose "View door" from the menu bar item and wait until the panel
#      disappears (success or failure).
#   3. Run this script within 30 minutes and paste the ENTIRE output.
#
#     bash scripts/video-diag.sh > ~/Desktop/video-diag.txt
#
# The report is redacted before being printed (see redact() below) but it
# still contains local IP addresses and hostnames -- see the footer.

set -u

APP_PATH="/Applications/GateOpener.app"
APP_INFO_PLIST="$APP_PATH/Contents/Info.plist"
PROCESS_NAME="GateOpener"
LOG_SUBSYSTEM="com.gateopener"
STUN_HOST="stun.cloud.comelitgroup.com"
CLOUD_URL="https://api.comelitgroup.com/"

# redact: filters stdin, replacing bearer tokens and JWT-shaped strings with
# [REDACTED]. Applied once, over the whole report, at the very end.
redact() {
	sed -E \
		-e 's/[Bb]earer [A-Za-z0-9._-]+/[REDACTED]/g' \
		-e 's/eyJ[A-Za-z0-9._-]{20,}/[REDACTED]/g'
}

# report: emits the entire plain-text report. Every section is independent
# -- a failure in one section must not prevent later sections from running.
report() {

	echo "GateOpener door video diagnostic report"
	echo "Generated: $(date)"
	echo
	echo "Before reading this report, make sure you followed these steps:"
	echo "  1. Quit and relaunch GateOpener."
	echo "  2. Choose \"View door\" from the menu bar item and wait until the panel disappears."
	echo "  3. Run this script within 30 minutes of that attempt and paste everything below."
	echo

	echo "=== APP ==="
	{
		local running_path=""
		local running_pid=""
		running_pid="$(pgrep -x "$PROCESS_NAME" 2>/dev/null | head -1)"
		if [ -n "$running_pid" ]; then
			running_path="$(ps -o comm= -p "$running_pid" 2>/dev/null)"
			echo "Running: yes (pid $running_pid)"
			echo "Running process path: ${running_path:-unknown}"
			echo "Process start time: $(ps -o lstart= -p "$running_pid" 2>/dev/null)"
		else
			echo "Running: not running"
		fi

		if [ -f "$APP_INFO_PLIST" ]; then
			local installed_short installed_build
			installed_short="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_INFO_PLIST" 2>/dev/null)"
			installed_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_INFO_PLIST" 2>/dev/null)"
			echo "Installed at $APP_PATH: ${installed_short:-unknown} (${installed_build:-unknown})"
		else
			echo "Installed at $APP_PATH: not installed"
		fi

		if [ -n "$running_path" ] && [ "$running_path" != "$PROCESS_NAME" ]; then
			# running_path is a bare comm name (e.g. "GateOpener"), not a
			# full bundle path, so also try to resolve the actual bundle
			# the running process was launched from, in case it differs
			# from /Applications.
			local running_bundle
			running_bundle="$(ps -o command= -p "$running_pid" 2>/dev/null | sed -E 's#/Contents/MacOS/.*##')"
			if [ -n "$running_bundle" ] && [ "$running_bundle" != "$APP_PATH" ] && [ -f "$running_bundle/Contents/Info.plist" ]; then
				local rb_short rb_build
				rb_short="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$running_bundle/Contents/Info.plist" 2>/dev/null)"
				rb_build="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$running_bundle/Contents/Info.plist" 2>/dev/null)"
				echo "Running process bundle ($running_bundle): ${rb_short:-unknown} (${rb_build:-unknown})"
			fi
		fi
	}
	echo

	echo "=== OS ==="
	sw_vers 2>&1
	echo

	echo "=== NETWORK ==="
	{
		echo "-- Interfaces with a non-loopback, non-link-local inet/inet6 address --"
		ifconfig 2>/dev/null | awk '
			/^[a-zA-Z0-9]+:/ { iface=$1; sub(/:$/, "", iface) }
			/inet /  { if ($2 !~ /^127\./)      print iface, $1, $2 }
			/inet6 / { if ($2 !~ /^fe80:/ && $2 != "::1") print iface, $1, $2 }
		'

		echo
		echo "-- Default route --"
		route -n get default 2>&1

		echo
		echo "-- utun interfaces --"
		local utun_list
		utun_list="$(ifconfig 2>/dev/null | awk '
			/^utun[0-9]+:/ { iface=$1; sub(/:$/, "", iface) }
			/inet / && iface { if ($2 !~ /^127\./) print iface, $2 }
			/inet6 / && iface { if ($2 !~ /^fe80:/ && $2 != "::1") print iface, $2 }
		')"
		if [ -n "$utun_list" ]; then
			echo "Count: $(echo "$utun_list" | wc -l | tr -d ' ')"
			echo "$utun_list"
		else
			echo "Count: 0"
		fi

		echo
		echo "-- DNS resolvers (scutil --dns, nameserver lines, de-duplicated) --"
		scutil --dns 2>/dev/null | grep -o 'nameserver\[[0-9]*\] : .*' | sort -u

		echo
		echo "-- VPN services (scutil --nc list) --"
		scutil --nc list 2>&1

		echo
		echo "-- Tailscale --"
		local ts_bin=""
		if [ -x /usr/local/bin/tailscale ]; then
			ts_bin=/usr/local/bin/tailscale
		elif [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
			ts_bin="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
		fi
		if [ -n "$ts_bin" ]; then
			echo "tailscale binary: $ts_bin"
			"$ts_bin" status --self --peers=false 2>&1
			echo
			"$ts_bin" exit-node list 2>&1
		else
			echo "tailscale: not found"
		fi
	}
	echo

	echo "=== FIREWALL ==="
	{
		local fw=/usr/libexec/ApplicationFirewall/socketfilterfw
		if [ -x "$fw" ]; then
			"$fw" --getglobalstate 2>&1
			"$fw" --getstealthmode 2>&1
			"$fw" --getblockall 2>&1
			echo
			echo "-- listapps | grep -i gate --"
			"$fw" --listapps 2>&1 | grep -i gate
		else
			echo "socketfilterfw: not found"
		fi
	}
	echo

	echo "=== STUN ==="
	{
		echo "-- dscacheutil (system resolver) --"
		dscacheutil -q host -a name "$STUN_HOST" 2>&1

		echo
		echo "-- dig --"
		if command -v dig >/dev/null 2>&1; then
			dig +short "$STUN_HOST" 2>&1
		else
			echo "dig: not found"
		fi
	}
	echo

	echo "=== CLOUD ==="
	{
		echo "Reachability check against $CLOUD_URL (no credentials sent):"
		curl -sS -o /dev/null -w 'http=%{http_code} total=%{time_total}s connect=%{time_connect}s\n' \
			--max-time 10 "$CLOUD_URL" 2>&1
	}
	echo

	echo "=== LOG ==="
	{
		echo "-- log show --predicate 'subsystem == \"$LOG_SUBSYSTEM\"' --last 30m --info --style compact --"
		local subsystem_log
		subsystem_log="$(log show --predicate "subsystem == \"$LOG_SUBSYSTEM\"" --last 30m --info --style compact 2>&1)"
		echo "$subsystem_log"

		local log_lines
		log_lines="$(echo "$subsystem_log" | grep -vc -E '^(Timestamp|Filtering the log data)')"
		echo
		echo "LOG LINES: $log_lines"

		echo
		echo "-- Fallback: log show --predicate 'process == \"$PROCESS_NAME\"' --last 30m --info --style compact | tail -200 --"
		log show --predicate "process == \"$PROCESS_NAME\"" --last 30m --info --style compact 2>&1 | tail -200
	}
	echo

	echo "=== END ==="
	echo "This report contains local IP addresses and hostnames from this Mac's"
	echo "network configuration. Review before sharing outside the intended"
	echo "recipient if that is a concern. Credentials and tokens are redacted."
}

report | redact
