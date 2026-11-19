#!/bin/sh
# qn10-usb3-fallback: try USB 3 on every USB-A port; if a device's
# SuperSpeed link never trains, run that port at USB 2 instead (as Windows
# does). Undo it when the device is unplugged.
#
# The QN10's USB-A ports sit behind an internal Genesys hub (USB2 half
# 05e3:0610 rev 94.06, SuperSpeed half 05e3:0625). A USB 3 KVM leaves its SS
# port stuck in Polling, and while it is stuck its USB 2 side does not
# enumerate either. Each fallback step runs once per plug-in; repeated port
# power cycles destabilised the xHC in testing.
#
# Per SS port, every POLL seconds:
#   Polling for STUCK checks -> SS off, one USB 2 power cycle (early_stop off)
#   USB 2 device is a hub    -> if its driver failed to bind, or it has
#                               connected ports but no working device,
#                               re-authorize it (up to KICKS times) so the hub
#                               driver reads its port status again. A hub with
#                               a working device is left alone.
#   USB 2 peer empty for GONE checks -> SS back on, early_stop restored.
#                               The KVM's USB 2 side connects only after its
#                               SS side tried and failed, so a KVM that
#                               switches away and back needs this SS retry.
set -u
POLL=2
STUCK=3
KICKS=3
KICK_GAP=5
GONE=10
STATE=/run/qn10-usb3-fallback
mkdir -p "$STATE"

log() { logger -t qn10-usb3-fallback "$*"; }

ss_hub() {
	for d in /sys/bus/usb/devices/*-1; do
		[ "$(cat "$d/idVendor" 2>/dev/null)" = 05e3 ] &&
			[ "$(cat "$d/idProduct" 2>/dev/null)" = 0625 ] && { echo "$d"; return; }
	done
}

# Link state text of one SS hub port, from the hub's port status.
link_state() { # hubdir port
	lsusb -v -s "$(cat "$1/busnum"):$(cat "$1/devnum")" 2>/dev/null |
		sed -n "s/^ *Port $2: [0-9a-f.]* \(.*\)$/\1/p"
}

while :; do
	S=$(ss_hub)
	if [ -n "$S" ]; then
		H=$(basename "$S")
		for p in "$S/$H:1.0/$H"-port*; do
			[ -e "$p" ] || continue
			n=${p##*-port}
			st=$STATE/$H-$n
			peer=$(readlink -f "$p/peer" 2>/dev/null)
			if [ "$(cat "$p/disable")" = 1 ]; then
				[ -f "$st.fallback" ] || continue # disabled by someone else
				child=$(readlink -e "$peer/device" 2>/dev/null)
				if [ -z "$child" ]; then
					# Device gone (or never enumerated) for GONE checks:
					# give the next device, or this one, a USB 3 try.
					g=$(($(cat "$st.gone" 2>/dev/null || echo 0) + 1))
					echo "$g" >"$st.gone"
					[ "$g" -ge "$GONE" ] || continue
					echo 0 >"$p/disable"
					[ -f "$st.es" ] && echo 1 >"$peer/early_stop"
					rm -f "$st" "$st.es" "$st.fallback" "$st.kicked" "$st.gone"
					log "port $n: no USB 2 device for $GONE checks, SuperSpeed back on"
					continue
				fi
				rm -f "$st.gone"
				if [ "$(cat "$child/bDeviceClass" 2>/dev/null)" = 09 ]; then
					# A hub: re-authorize it (at most KICKS times, KICK_GAP
					# apart) while its hub driver failed to bind, or while a
					# port reports a connection with no device on it.
					k=$(cat "$st.kicked" 2>/dev/null || echo 0)
					[ "$k" -lt "$KICKS" ] || continue
					b=$(basename "$child")
					if [ -e "$child/$b:1.0/driver" ]; then
						# Never disturb a hub that already has a working
						# device (re-authorizing drops it); only kick a hub
						# with connected ports but nothing enumerated.
						kids=$(find "$child"/ -maxdepth 1 -name "$b.*" | wc -l)
						[ "$kids" -eq 0 ] || continue
						conn=$(lsusb -v -s "$(cat "$child/busnum"):$(cat "$child/devnum")" 2>/dev/null |
							grep -cE '^ +Port [0-9]+: .* connect$')
						[ "$conn" -gt 0 ] || continue
						why="$conn connected ports, no devices"
					else
						why="no hub driver bound"
					fi
					sleep "$KICK_GAP"
					echo 0 >"$child/authorized"
					echo 1 >"$child/authorized"
					echo $((k + 1)) >"$st.kicked"
					log "port $n: hub $b: $why; re-authorized ($((k + 1))/$KICKS)"
				fi
				continue
			fi
			case "$(link_state "$S" "$n")" in
			*Polling*)
				c=$(($(cat "$st" 2>/dev/null || echo 0) + 1))
				echo "$c" >"$st"
				[ "$c" -ge "$STUCK" ] || continue
				echo 1 >"$p/disable"
				: >"$st.fallback"
				log "port $n: SuperSpeed stuck in Polling, using USB 2"
				[ -n "$peer" ] || continue
				[ "$(cat "$peer/early_stop")" = yes ] && : >"$st.es"
				echo 0 >"$peer/early_stop"
				echo 1 >"$peer/disable"
				sleep 2
				echo 0 >"$peer/disable"
				;;
			*) rm -f "$st" ;;
			esac
		done
	fi
	sleep "$POLL"
done
