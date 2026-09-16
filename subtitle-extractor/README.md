# MKV Subtitle Extractor

Bash script that extracts Italian and English subtitle tracks from MKV files and saves them as external `.srt` files.

The main purpose is to allow Emby to use external text subtitles, reducing cases where subtitle handling causes unnecessary video transcoding.

## Requirements

* Bash
* `jq`
* `ass2srt`
* MKVToolNix:

  * `mkvmerge`
  * `mkvextract`

## MKVToolNix configuration

The current script uses MKVToolNix from an extracted portable/AppImage filesystem:

```bash
export LD_LIBRARY_PATH="/mnt/user/Merce/MKVToolnix/squashfs-root/usr/lib"

MKVMERGE="/mnt/user/Merce/MKVToolnix/squashfs-root/usr/bin/mkvmerge"
MKVEXTRACT="/mnt/user/Merce/MKVToolnix/squashfs-root/usr/bin/mkvextract"
```

Change these paths if MKVToolNix is installed elsewhere.

`LD_LIBRARY_PATH` is required in this setup so that `mkvmerge` and `mkvextract` can find the libraries included with the extracted MKVToolNix package.

## Usage

Pass one movie directory:

```bash
./extract_subtitles.sh "/mnt/user/Media/Film/Movie Name (2024)"
```

Multiple directories can also be supplied:

```bash
./extract_subtitles.sh \
    "/mnt/user/Media/Film/Movie One (2024)" \
    "/mnt/user/Media/Film/Movie Two (2025)"
```

The script processes `.mkv` files located directly inside each supplied directory.

## Supported subtitles

The script processes Italian and English text subtitles using:

* `S_TEXT/UTF8`
* `S_TEXT/ASS`
* `S_TEXT/SSA`

UTF-8 subtitles are extracted directly.

ASS and SSA subtitles are extracted and converted to SRT using `ass2srt`.

## File naming

Examples:

```text
Movie Name.it.srt
Movie Name.en.srt
Movie Name.it.forced.srt
Movie Name.en.forced.srt
```

Forced subtitles are detected either through the MKV forced-track flag or when the track name contains:

```text
forced
forzato
```

## Default subtitle selection

If no external subtitle is already marked as default, the script uses this priority:

1. Italian forced
2. Italian
3. English forced
4. English

The selected subtitle is renamed accordingly.

Example:

```text
Movie Name.it.forced.default.srt
```

## Existing files

If the corresponding subtitle already exists, the extraction is skipped.

This includes both the standard filename and its `.default.srt` variant.

## Permissions

At the end of processing, generated `.srt` files are configured as:

```text
owner: nobody
group: users
mode: 664
```

This is intended for an Unraid environment.

Change the ownership or permissions in the script if required on another system.
