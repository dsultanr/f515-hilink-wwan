#!/system/bin/sh
# Перечисляет съёмные USB mass-storage устройства и (по явному выбору пользователя в
# приложении) форматирует одно из них: MBR, один раздел 0x0c (Win95 FAT32, LBA) со
# старта LBA 2048 (1MiB-выравнивание) на весь диск, файловая система exFAT - структурно
# идентично заводской разметке SD/TF-карты, но без привязки к конкретному объёму.
#
# На этой платформе /sys/block/sd* - всегда USB SCSI mass-storage (модем, флешка и т.п.),
# внутреннее хранилище живёт на /dev/block/vd*|dm-*, поэтому список сам по себе не может
# случайно содержать системный раздел. Какое именно устройство форматировать - решает
# пользователь в приложении (после явного подтверждения), скрипт сам ничего не угадывает.
#
#   format-sdcard.sh --list           напечатать кандидатов, ничего не менять
#   format-sdcard.sh --format=sdX     стереть и переразметить /dev/block/sdX
TMP=/data/local/tmp
LOG=$TMP/f515hilinkwwan.log

log() { echo "$(date '+%F %T') format-sdcard: $*" >> $LOG; }

human_size() {
    # $1 - размер в 512-байтных секторах
    awk -v s="$1" 'BEGIN {
        b = s * 512
        if (b >= 1073741824) printf "%.1fG", b/1073741824
        else if (b >= 1048576) printf "%.1fM", b/1048576
        else printf "%dK", b/1024
    }'
}

list_candidates() {
    for d in /sys/block/sd*; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        sectors=$(cat "$d/size" 2>/dev/null)
        [ -n "$sectors" ] || continue
        vendor=$(cat "$d/device/vendor" 2>/dev/null | sed 's/^ *//;s/ *$//')
        model=$(cat "$d/device/model" 2>/dev/null | sed 's/^ *//;s/ *$//')
        size=$(human_size "$sectors")
        part="/dev/block/${name}1"
        fstype=""
        label=""
        if [ -b "$part" ]; then
            info=$(blkid "$part" 2>/dev/null)
            fstype=$(echo "$info" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
            label=$(echo "$info" | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
        fi
        echo "${name}|${vendor}|${model}|${size}|${fstype}|${label}"
    done
}

do_format() {
    dev=$1
    case "$dev" in
        sd[a-z]) ;;
        *) echo "недопустимое имя устройства: $dev"; exit 1 ;;
    esac
    node="/dev/block/$dev"
    if [ ! -b "$node" ]; then
        echo "$node не найден"
        log "format: $node not found"
        exit 1
    fi

    echo "размонтирую разделы $dev..."
    for p in ${node}*; do
        [ "$p" = "$node" ] && continue
        mp=$(mount | grep "^$p " | awk '{print $3}')
        [ -n "$mp" ] && umount "$p" 2>/dev/null
    done

    echo "создаю разметку (MBR, раздел 1, старт LBA 2048, на весь диск, тип 0x0c)..."
    printf "o\nn\np\n1\n2048\n\nt\nc\nw\n" | busybox fdisk "$node" >>$LOG 2>&1
    sync
    sleep 1
    blockdev --rereadpt "$node" 2>/dev/null

    part="${node}1"
    i=0
    while [ ! -b "$part" ] && [ $i -lt 5 ]; do
        sleep 1
        i=$((i + 1))
    done
    if [ ! -b "$part" ]; then
        echo "раздел $part не появился после разметки"
        log "format: $part missing after fdisk"
        exit 1
    fi

    echo "форматирую $part в exFAT..."
    if mkfs.exfat "$part" >>$LOG 2>&1; then
        log "format complete: $part"
        echo "готово: $part отформатирован (exFAT)"
    else
        echo "mkfs.exfat завершился с ошибкой"
        log "format: mkfs.exfat failed on $part"
        exit 1
    fi
}

case "$1" in
    --list)
        list_candidates
        ;;
    --format=*)
        do_format "${1#--format=}"
        ;;
    *)
        echo "usage: format-sdcard.sh --list | --format=sdX"
        exit 1
        ;;
esac
