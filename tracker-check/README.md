# Tracker Library Check

Perl script used to compare a local movie or TV library with the content available on a UNIT3D-based tracker.

The script primarily identifies media using TMDB and IMDb IDs extracted from local `.nfo` files.

If no usable ID is available, it falls back to a tracker API search using the directory name and, for movies, the release year.

## Requirements

* Perl
* `curl`
* Perl modules:

  * `JSON::PP`
  * `File::Basename`
  * `File::Glob`
  * `Getopt::Long`

## Configuration

Configure the tracker API URL and API token inside the script:

```perl
my $API_URL   = 'https://tracker.example/api/torrents/filter';
my $API_TOKEN = 'YOUR_API_TOKEN';
```

Do not commit a real API token to a public repository.

The script currently uses:

* category `1` for movies
* category `2` for TV shows

## Usage

### Movies

```bash
perl tracker_check.pl '/mnt/user/Media/Film/*'
```

### TV Shows

```bash
perl tracker_check.pl '/mnt/user/Media/Serie Tv/*'
```

### Force tracker cache refresh

```bash
perl tracker_check.pl --refresh '/mnt/user/Media/Film/*'
```

## How it works

The script downloads the tracker catalogue and stores it locally as JSON cache.

When `.nfo` files are available, it extracts TMDB and IMDb IDs and compares them directly with the tracker catalogue.

For movies, it searches for:

```text
<Movie Directory Name>.nfo
```

and then falls back to the first `.nfo` file found in the directory.

For TV shows it searches for:

```text
tvshow.nfo
```

If no usable TMDB or IMDb ID is found, the script performs an API lookup using the media title.

For movies whose directory name ends with a year:

```text
Alien (1979)
```

the year is also included in the fallback search.

## Output

Missing movies are written to:

```text
bulk_missing_movies.json
```

Missing TV shows are written to:

```text
bulk_missing_tv.json
```

Tracker caches are stored as:

```text
tracker_category_1.json
tracker_category_2.json
```

The final output also includes a summary of:

* titles found
* titles missing
* errors
* titles without metadata IDs

## API Rate Limiting

HTTP `429 Too Many Requests` responses are handled automatically using retries with exponential backoff.
