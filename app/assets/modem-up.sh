#!/system/bin/sh
# Brings up a USB HiLink-style modem (cdc_ether - ZTE MF833R/MF831/MF833U, Huawei в
# HiLink-режиме и похожие, любой вендор) as WAN and fixes the phantom-TBOX DNS so Android
# (and apps/NTP) actually treat it as internet. No WireGuard, no daemon - one shot,
# idempotent, safe to run again. Runs as root (adbd on this build already is root).
#
#   modem-up.sh          подъём (меняет состояние по необходимости)
#   modem-up.sh --check  только диагностика, ничего не меняет
TMP=/data/local/tmp
LOG=$TMP/f515hilinkwwan.log
FALLBACK_IF=eth1
FALLBACK_ADDR=192.168.0.178
FALLBACK_GW=192.168.0.1
FALLBACK_TBOX_IF=vlan72
FALLBACK_TBOX_DNS=192.168.72.1

CHECK_ONLY=0
[ "$1" = "--check" ] && CHECK_ONLY=1

log() { echo "$(date '+%F %T') modem-up: $*" >> $LOG; }

# Ищем сетевой интерфейс HiLink-модема по драйверу, а не по вендору/MAC/имени интерфейса -
# HiLink-модемы (любого производителя) отдают себя как USB CDC-Ethernet устройство и
# привязываются к драйверу cdc_ether (реже rndis_host); ни MAC, ни имя интерфейса, ни
# vendor ID между моделями/головами не совпадают, а вот тип USB-класса устройства - да.
modem_iface() {
    for d in /sys/class/net/*; do
        drv=$(readlink -f "$d/device/driver" 2>/dev/null) || continue
        dev=$(readlink -f "$d/device" 2>/dev/null)
        case "$dev" in
            */usb*/*) ;;   # интерфейс должен висеть на USB, а не быть встроенным
            *) continue ;;
        esac
        case "$(basename "$drv")" in
            cdc_ether | rndis_host)
                basename "$d"
                return 0
                ;;
        esac
    done
    [ -d /sys/class/net/$FALLBACK_IF ] && { echo $FALLBACK_IF; return 0; }
    return 1
}

if ! IF=$(modem_iface); then
    log "modem interface not found"
    echo "modem interface not found"
    echo
    echo "== сетевые интерфейсы и их драйверы =="
    for d in /sys/class/net/*; do
        [ -f "$d/address" ] || continue
        drv=$(readlink -f "$d/device/driver" 2>/dev/null)
        dev=$(readlink -f "$d/device" 2>/dev/null)
        usb=no
        case "$dev" in */usb*/*) usb=yes ;; esac
        echo "  $(basename "$d"): mac=$(cat "$d/address" 2>/dev/null) driver=$(basename "${drv:-?}") usb=$usb"
    done
    echo
    echo "== USB-устройства (видны ли вообще на шине) =="
    found_usb=0
    for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        found_usb=1
        echo "  $(basename "$d"): $(cat "$d/idVendor"):$(cat "$d/idProduct" 2>/dev/null)" \
             "class=$(cat "$d/bDeviceClass" 2>/dev/null)" \
             "product=\"$(cat "$d/product" 2>/dev/null)\"" \
             "manufacturer=\"$(cat "$d/manufacturer" 2>/dev/null)\""
    done
    [ "$found_usb" = 1 ] || echo "  (пусто - ни одного USB-устройства с idVendor не найдено)"
    echo
    echo "== драйвер cdc_ether/rndis_host загружен? =="
    lsmod 2>/dev/null | grep -E "cdc_ether|usbnet|rndis_host|cdc_ncm" ||
        echo "  не найден в lsmod (может быть встроен в ядро статически, а не модулем - тогда это нормально)"
    echo
    echo "== последние USB-события в dmesg =="
    dmesg 2>/dev/null | grep -iE "usb|cdc_ether|rndis|cdc_acm" | tail -20
    echo
    echo "если модем в списке USB-устройств есть, но не стал сетевым интерфейсом -"
    echo "смотри driver= у него в выводе выше и класс USB-устройства (class=)."
    exit 1
fi
log "using interface $IF"

# --- WAN -------------------------------------------------------------------
if ! ip -4 addr show "$IF" | grep -q 'inet '; then
    if [ "$CHECK_ONLY" = 1 ]; then
        echo "[dry] $IF: адреса нет, был бы поднят (up + udhcpc)"
    else
        ip link set "$IF" up
        i=0
        while [ $i -lt 30 ]; do
            [ "$(cat /sys/class/net/$IF/carrier 2>/dev/null)" = "1" ] && break
            sleep 1
            i=$((i + 1))
        done

        # HiLink modem does its own NAT+DHCP. udhcpc gets the lease but does not apply it
        # here (no default script), so parse and configure by hand.
        LEASE=$(busybox udhcpc -i "$IF" -q -n -f 2>&1)
        ADDR=$(echo "$LEASE" | sed -n 's/.*lease of \([0-9.]*\) obtained from \([0-9.]*\).*/\1/p' | tail -1)
        GW=$(echo "$LEASE" | sed -n 's/.*lease of \([0-9.]*\) obtained from \([0-9.]*\).*/\2/p' | tail -1)
        [ -n "$ADDR" ] || ADDR=$FALLBACK_ADDR
        [ -n "$GW" ] || GW=$FALLBACK_GW

        ip addr replace "$ADDR/24" dev "$IF"
        ip route replace default via "$GW" dev "$IF" metric 10
        log "$IF up: $ADDR via $GW"
    fi
else
    log "$IF already has an address"
fi

# --- phantom TBOX: make ConnectivityService's cellular network usable -------
# The vendor's "Tbox" provider keeps a CELLULAR NetworkAgent alive with a gw/DNS that
# nothing answers on (real TBOX is physically gone). Routing already works (vendor rules
# 9990-9999: from all lookup main win over every fwmark rule, and main has our default via
# the modem) - the only thing missing is a reachable DNS server: without it the network
# never validates, Android reports "no internet", and NTP stops too.
discover_tbox() {
    line=$(dumpsys connectivity 2>/dev/null | grep -m1 'type: Tbox')
    [ -n "$line" ] || line=$(dumpsys connectivity 2>/dev/null | grep -m1 'Transports: CELLULAR')

    TBOX_IF=$(echo "$line" | sed -n 's/.*InterfaceName: \([a-z0-9._-]*\).*/\1/p')
    TBOX_DNS=$(echo "$line" | sed -n 's/.*DnsAddresses: \[ *\/\([0-9.]*\).*/\1/p')

    if [ -z "$TBOX_IF" ] || [ -z "$TBOX_DNS" ]; then
        TBOX_IF=$FALLBACK_TBOX_IF
        TBOX_DNS=$FALLBACK_TBOX_DNS
        log "tbox: ConnectivityService gave nothing, falling back to $TBOX_IF/$TBOX_DNS"
    fi
    TBOX_SRC=$(ip -o -4 addr show "$TBOX_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
}

ensure_tbox_dns() {
    GW=$(ip route show table main | grep '^default' | head -1 | cut -d' ' -f3)
    [ -n "$GW" ] || { log "no default route yet, skipping tbox dns"; return; }

    discover_tbox
    [ -n "$TBOX_SRC" ] || { log "tbox: $TBOX_IF has no address, skipping"; return; }
    [ "$TBOX_DNS" = "$GW" ] && { log "tbox dns == modem gw, nothing to do"; return; }

    # If that DNS already answers there is nothing to fix: either our rules are in place
    # from an earlier run, or a real TBOX is back - in that case touching nat would hijack
    # a working resolver.
    if timeout 6 busybox nslookup connectivitycheck.gstatic.com "$TBOX_DNS" >/dev/null 2>&1; then
        log "tbox dns $TBOX_DNS answers already - nat untouched"
        return
    fi

    OLD=$(iptables -w 10 -t nat -S OUTPUT 2>/dev/null | grep "$TBOX_DNS" | grep -v "to-destination $GW:53")
    [ -n "$OLD" ] && log "WARNING: stale tbox dns rule(s) present, remove by hand: $OLD"

    if [ "$CHECK_ONLY" = 1 ]; then
        echo "[dry] DNAT $TBOX_DNS:53 -> $GW:53, MASQUERADE $TBOX_SRC через $IF"
        return
    fi

    for proto in udp tcp; do
        iptables -w 10 -t nat -C OUTPUT -d $TBOX_DNS -p $proto --dport 53 \
            -j DNAT --to-destination $GW:53 2>/dev/null ||
        iptables -w 10 -t nat -A OUTPUT -d $TBOX_DNS -p $proto --dport 53 \
            -j DNAT --to-destination $GW:53
    done
    iptables -w 10 -t nat -C POSTROUTING -s $TBOX_SRC -o "$IF" -j MASQUERADE 2>/dev/null ||
    iptables -w 10 -t nat -A POSTROUTING -s $TBOX_SRC -o "$IF" -j MASQUERADE
    log "tbox dns $TBOX_DNS ($TBOX_IF, src $TBOX_SRC) -> $GW via $IF"
}

ensure_tbox_dns

# --- report ------------------------------------------------------------------
echo "interface: $IF"
ip -4 addr show "$IF" | grep inet
echo "default route:"
ip route show table main | grep '^default'
echo "active default network:"
dumpsys connectivity 2>/dev/null | grep -A1 '^Active default network'
if timeout 5 ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    echo "internet: reachable (ping 8.8.8.8 ok)"
else
    echo "internet: ping 8.8.8.8 failed"
fi
log "run complete"
