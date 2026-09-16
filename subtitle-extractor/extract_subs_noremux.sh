#!/bin/bash

export LD_LIBRARY_PATH="/mnt/user/Merce/MKVToolnix/squashfs-root/usr/lib"

MKVMERGE="/mnt/user/Merce/MKVToolnix/squashfs-root/usr/bin/mkvmerge"
MKVEXTRACT="/mnt/user/Merce/MKVToolnix/squashfs-root/usr/bin/mkvextract"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 /path/to/movie_directory [more_dirs...]"
    exit 1
fi

for TARGET in "$@"; do

    if [ ! -d "$TARGET" ]; then
        echo "Directory not found: $TARGET"
        continue
    fi

    find "$TARGET" -maxdepth 1 -type f -name "*.mkv" | while read -r FILE; do

        DIR="$(dirname "$FILE")"
        NAME="$(basename "$FILE" .mkv)"

        echo "Processing: $FILE"

        # ==========================
        # 1. Estrazione sottotitoli
        # ==========================
        "$MKVMERGE" -J "$FILE" | jq -c '
            .tracks[]
            | select(.type=="subtitles")
            | select(
                .properties.codec_id=="S_TEXT/UTF8" or
                .properties.codec_id=="S_TEXT/ASS" or
                .properties.codec_id=="S_TEXT/SSA"
            )
            | select(.properties.language=="ita" or .properties.language=="eng")
        ' | while read -r TRACK; do

            ID=$(echo "$TRACK" | jq '.id')
            LANG=$(echo "$TRACK" | jq -r '.properties.language')
            CODEC=$(echo "$TRACK" | jq -r '.properties.codec_id')
            FORCED=$(echo "$TRACK" | jq -r '.properties.forced_track // false')
            TRACK_NAME=$(echo "$TRACK" | jq -r '.properties.track_name // ""')

            # Se nel nome contiene Forced o Forzato -> consideralo forced
            if echo "$TRACK_NAME" | grep -Eiq "(forced|forzato)"; then
                FORCED="true"
            fi

            # ISO3 -> ISO2
            [ "$LANG" = "ita" ] && LANG="it"
            [ "$LANG" = "eng" ] && LANG="en"

            if [ "$FORCED" = "true" ]; then
                OUT="$DIR/$NAME.$LANG.forced.srt"
                DEFAULT_OUT="$DIR/$NAME.$LANG.forced.default.srt"
            else
                OUT="$DIR/$NAME.$LANG.srt"
                DEFAULT_OUT="$DIR/$NAME.$LANG.default.srt"
            fi

            # Se esiste già normale oppure già marcato default, salta
            if [ -f "$OUT" ] || [ -f "$DEFAULT_OUT" ]; then
                echo "  -> Subtitle already exists, skipping: $(basename "$OUT")"
                continue
            fi

            echo "  -> Extracting track $ID ($CODEC)"

            # Determina estensione temporanea coerente col codec
            if [ "$CODEC" = "S_TEXT/UTF8" ]; then
                TMP_EXT="srt"
            elif [ "$CODEC" = "S_TEXT/ASS" ]; then
                TMP_EXT="ass"
            elif [ "$CODEC" = "S_TEXT/SSA" ]; then
                TMP_EXT="ssa"
            else
                TMP_EXT="sub"
            fi

            TMP_SUB="$DIR/$NAME.$LANG.$ID.$TMP_EXT"

            "$MKVEXTRACT" tracks "$FILE" "$ID:$TMP_SUB"

            if [ "$CODEC" = "S_TEXT/UTF8" ]; then

                if [ -s "$TMP_SUB" ]; then
                    mv "$TMP_SUB" "$OUT"
                    echo "  -> Saved as $OUT"
                else
                    echo "  !! Extraction failed for $TMP_SUB"
                    rm -f "$TMP_SUB"
                fi

            else

                # ASS / SSA -> SRT con ass2srt
                /usr/bin/ass2srt -o "$OUT" "$TMP_SUB"

                if [ -s "$OUT" ]; then
                    echo "  -> Saved as $OUT"
                    rm -f "$TMP_SUB"
                else
                    echo "  !! Conversion failed for $TMP_SUB"
                    rm -f "$OUT"
                    rm -f "$TMP_SUB"
                fi
            fi

        done


        # ==========================
        # 2. Selezione DEFAULT
        #
        # Priorità:
        # 1) IT forced
        # 2) IT normale
        # 3) EN forced
        # 4) EN normale
        # ==========================

        EXISTING_DEFAULT=""

        for CANDIDATE in \
            "$DIR/$NAME.it.forced.default.srt" \
            "$DIR/$NAME.it.default.srt" \
            "$DIR/$NAME.en.forced.default.srt" \
            "$DIR/$NAME.en.default.srt"
        do
            if [ -f "$CANDIDATE" ]; then
                EXISTING_DEFAULT="$CANDIDATE"
                break
            fi
        done

        if [ -n "$EXISTING_DEFAULT" ]; then

            echo "  -> Default already set: $(basename "$EXISTING_DEFAULT")"

        else

            DEFAULT_SUB=""
            DEFAULT_NAME=""

            if [ -f "$DIR/$NAME.it.forced.srt" ]; then

                DEFAULT_SUB="$DIR/$NAME.it.forced.srt"
                DEFAULT_NAME="$DIR/$NAME.it.forced.default.srt"

            elif [ -f "$DIR/$NAME.it.srt" ]; then

                DEFAULT_SUB="$DIR/$NAME.it.srt"
                DEFAULT_NAME="$DIR/$NAME.it.default.srt"

            elif [ -f "$DIR/$NAME.en.forced.srt" ]; then

                DEFAULT_SUB="$DIR/$NAME.en.forced.srt"
                DEFAULT_NAME="$DIR/$NAME.en.forced.default.srt"

            elif [ -f "$DIR/$NAME.en.srt" ]; then

                DEFAULT_SUB="$DIR/$NAME.en.srt"
                DEFAULT_NAME="$DIR/$NAME.en.default.srt"

            fi

            if [ -n "$DEFAULT_SUB" ]; then
                mv "$DEFAULT_SUB" "$DEFAULT_NAME"
                echo "  -> Default subtitle: $(basename "$DEFAULT_NAME")"
            else
                echo "  -> No usable IT/EN subtitles found"
            fi

        fi


        # ==========================
        # 3. Permessi
        # ==========================

        chown nobody:users "$DIR"/*.srt 2>/dev/null
        chmod 664 "$DIR"/*.srt 2>/dev/null

        echo "  -> Done"
        echo

    done

done