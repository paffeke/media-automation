#!/usr/bin/perl

use strict;
use warnings;

use JSON::PP;
use File::Basename qw(basename);
use File::Glob qw(bsd_glob);
use Getopt::Long qw(GetOptions);

# ============================================================
# CONFIGURAZIONE
# ============================================================

my $API_URL   = 'https://tracker.example/api/torrents/filter';
my $API_TOKEN = '*****';

# Proviamo a chiedere 100 torrent per pagina.
# Se UNIT3D limita internamente il valore, userà il suo massimo.
my $PER_PAGE = 100;

# Piccola pausa tra una pagina e la successiva.
my $PAGE_DELAY = 0.5;

# Numero massimo di retry in caso di HTTP 429.
my $MAX_RETRIES = 6;

# Directory dove salvare le cache.
my $CACHE_DIR = '.';

# ============================================================
# OPZIONI
# ============================================================

my $refresh = 0;

GetOptions(
    'refresh' => \$refresh,
) or die usage();

my $pattern = shift @ARGV;

die usage() unless defined $pattern;

sub usage {
    return <<"USAGE";

Uso:

  Film:
    $0 '/mnt/user/Media/Film/*'

  Serie TV:
    $0 '/mnt/user/Media/Serie Tv/*'

  Forza aggiornamento cache:
    $0 --refresh '/mnt/user/Media/Film/*'

USAGE
}

# ============================================================
# TIPO MEDIA / CATEGORIA
# ============================================================

my ($media_type, $category, $missing_file, $cache_file);

if ($pattern =~ m{/Film(?:/|$)}i) {

    $media_type   = 'movie';
    $category     = 1;

    $missing_file = 'bulk_missing_movies.txt';
    $cache_file   = "$CACHE_DIR/tracker_category_1.json";
}
elsif ($pattern =~ m{/Serie Tv(?:/|$)}i) {

    $media_type   = 'tv';
    $category     = 2;

    $missing_file = 'bulk_missing_tv.txt';
    $cache_file   = "$CACHE_DIR/tracker_category_2.json";
}
else {

    die "ERRORE: impossibile determinare Film/Serie Tv dal percorso:\n$pattern\n";
}

# ============================================================
# DIRECTORY LOCALI
# ============================================================

my @dirs = grep { -d $_ } bsd_glob($pattern);

@dirs = sort @dirs;

die "Nessuna directory trovata per:\n$pattern\n"
    unless @dirs;

print "\n";
print "Tipo          : $media_type\n";
print "Categoria     : $category\n";
print "Directory     : " . scalar(@dirs) . "\n";
print "Cache         : $cache_file\n";
print "Refresh cache : " . ($refresh ? 'SI' : 'NO') . "\n";
print "\n";

# ============================================================
# UTILITY
# ============================================================

sub sleep_fractional {
    my ($seconds) = @_;
    select(undef, undef, undef, $seconds);
}

sub normalize_imdb {

    my ($id) = @_;

    return undef unless defined $id;

    $id =~ s/^\s+//;
    $id =~ s/\s+$//;

    $id =~ s/^tt//i;

    return undef unless $id =~ /^\d+$/;

    # Il tracker restituisce IMDb come numero.
    # Esempio:
    # tt0343818 -> 343818
    $id =~ s/^0+//;

    return $id || '0';
}

# ============================================================
# NFO
# ============================================================

sub find_nfo {

    my ($dir) = @_;

    if ($media_type eq 'tv') {

        my $file = "$dir/tvshow.nfo";

        return $file if -f $file;

        return undef;
    }

    my $base = basename($dir);

    my $preferred = "$dir/$base.nfo";

    return $preferred if -f $preferred;

    my @files = bsd_glob("$dir/*.nfo");

    return $files[0] if @files;

    return undef;
}

sub parse_nfo_ids {

    my ($file) = @_;

    return (undef, undef)
        unless defined $file && -f $file;

    open my $fh, '<', $file
        or return (undef, undef);

    local $/;
    my $xml = <$fh>;
    close $fh;

    my ($tmdb, $imdb);

    # --------------------------------------------------------
    # TMDB
    # --------------------------------------------------------

    if (
        $xml =~ m{
            <uniqueid
            [^>]*type\s*=\s*["']tmdb["']
            [^>]*>
            \s*(\d+)\s*
            </uniqueid>
        }ix
    ) {
        $tmdb = $1;
    }
    elsif (
        $xml =~ m{
            <tmdbid>
            \s*(\d+)\s*
            </tmdbid>
        }ix
    ) {
        $tmdb = $1;
    }

    # --------------------------------------------------------
    # IMDb
    # --------------------------------------------------------

    if (
        $xml =~ m{
            <uniqueid
            [^>]*type\s*=\s*["']imdb["']
            [^>]*>
            \s*(?:tt)?(\d+)\s*
            </uniqueid>
        }ix
    ) {
        $imdb = normalize_imdb($1);
    }
    elsif (
        $xml =~ m{
            <imdbid>
            \s*(?:tt)?(\d+)\s*
            </imdbid>
        }ix
    ) {
        $imdb = normalize_imdb($1);
    }
    elsif (
        $xml =~ m{
            <id>
            \s*tt(\d+)\s*
            </id>
        }ix
    ) {
        $imdb = normalize_imdb($1);
    }

    return ($tmdb, $imdb);
}

sub directory_title_year {

    my ($dir) = @_;

    my $name = basename($dir);

    my $year;

    if (
        $media_type eq 'movie'
        &&
        $name =~ s/\s*\((\d{4})\)\s*$//
    ) {
        $year = $1;
    }

    return ($name, $year);
}

# ============================================================
# API
# ============================================================

sub api_request {

    my (%params) = @_;

    my @cmd = (
        'curl',
        '-sS',
        '-G',
        '--write-out', "\n%{http_code}",
        $API_URL,
        '--data-urlencode', "api_token=$API_TOKEN",
    );

    for my $key (sort keys %params) {

        next unless defined $params{$key};

        push @cmd,
            '--data-urlencode',
            "$key=$params{$key}";
    }

    open my $fh, '-|', @cmd
        or return (undef, 0, "Impossibile eseguire curl: $!");

    local $/;

    my $output = <$fh>;

    close $fh;

    return (undef, 0, 'Nessun output da curl')
        unless defined $output;

    my ($body, $http_status)
        = $output =~ /\A(.*)\n(\d{3})\z/s;

    return (undef, 0, 'HTTP status non leggibile')
        unless defined $http_status;

    return ($body, int($http_status), undef);
}

sub api_request_retry {

    my (%params) = @_;

    for my $attempt (1 .. $MAX_RETRIES) {

        my ($body, $status, $error)
            = api_request(%params);

        return (undef, $status, $error)
            if $error;

        if ($status == 429) {

            my $wait = 2 ** $attempt;

            print "\n";
            print "[429] Rate limit raggiunto.\n";
            print "      Attendo ${wait}s ";
            print "e riprovo ($attempt/$MAX_RETRIES)...\n";

            sleep($wait);

            next;
        }

        if ($status < 200 || $status >= 300) {

            return (
                undef,
                $status,
                "HTTP $status"
            );
        }

        return ($body, $status, undef);
    }

    return (
        undef,
        429,
        "Troppi HTTP 429 consecutivi"
    );
}

# ============================================================
# CACHE
# ============================================================

sub load_cache {

    my ($file) = @_;

    open my $fh, '<', $file
        or die "Impossibile leggere cache $file: $!\n";

    local $/;

    my $json = <$fh>;

    close $fh;

    my $data;

    eval {
        $data = decode_json($json);
    };

    die "Cache JSON non valida: $file\n"
        if $@ || ref($data) ne 'HASH';

    return $data;
}

sub save_cache {

    my ($file, $data) = @_;

    open my $fh, '>', $file
        or die "Impossibile scrivere cache $file: $!\n";

    my $json = JSON::PP
        ->new
        ->ascii
        ->pretty
        ->canonical
        ->encode($data);

    print $fh $json;

    close $fh;
}

# ============================================================
# DOWNLOAD COMPLETO TRACKER
# ============================================================

sub download_tracker_cache {

    print "Scaricamento completo categoria $category...\n\n";

    my @torrents;

    my $page = 1;

    while (1) {

        print "\rPagina $page - torrent raccolti: "
            . scalar(@torrents);

        my ($body, $status, $error)
            = api_request_retry(
                'categories[]' => $category,
                'perPage'      => $PER_PAGE,
                'page'         => $page,
            );

        die "\nERRORE API pagina $page: $error\n"
            if $error;

        my $json;

        eval {
            $json = decode_json($body);
        };

        die "\nJSON non valido alla pagina $page\n"
            if $@ || ref($json) ne 'HASH';

        my $data = $json->{data};

        die "\nCampo data non valido alla pagina $page\n"
            unless ref($data) eq 'ARRAY';

        last unless @$data;

        for my $torrent (@$data) {

            next unless ref($torrent) eq 'HASH';

            my $attr = $torrent->{attributes};

            next unless ref($attr) eq 'HASH';

            push @torrents, {

                id => $torrent->{id},

                name => $attr->{name},

                tmdb_id => $attr->{tmdb_id},

                imdb_id => $attr->{imdb_id},

                release_year => $attr->{release_year},

                category_id => $attr->{category_id},
            };
        }

        my $next;

        if (
            ref($json->{links}) eq 'HASH'
        ) {
            $next = $json->{links}{next};
        }

        last unless defined $next && length $next;

        $page++;

        sleep_fractional($PAGE_DELAY);
    }

    print "\n\n";

    my $cache = {

        generated_at => scalar localtime(),

        category => $category,

        torrent_count => scalar(@torrents),

        torrents => \@torrents,
    };

    save_cache(
        $cache_file,
        $cache
    );

    print "Cache salvata:\n";
    print "  $cache_file\n";
    print "\n";
    print "Torrent salvati: "
        . scalar(@torrents)
        . "\n\n";

    return $cache;
}

# ============================================================
# CARICA O CREA CACHE
# ============================================================

my $cache;

if (
    !$refresh
    &&
    -f $cache_file
) {

    print "Uso cache esistente...\n\n";

    $cache = load_cache($cache_file);
}
else {

    $cache = download_tracker_cache();
}

# ============================================================
# COSTRUISCE INDICI IN RAM
# ============================================================

my %tracker_tmdb;
my %tracker_imdb;

my $torrent_count = 0;

for my $torrent (
    @{ $cache->{torrents} // [] }
) {

    next unless ref($torrent) eq 'HASH';

    my $name = $torrent->{name} // '';

    my $tmdb = $torrent->{tmdb_id};

    my $imdb = normalize_imdb(
        $torrent->{imdb_id}
    );

    if (
        defined $tmdb
        &&
        $tmdb =~ /^\d+$/
        &&
        $tmdb > 0
    ) {

        # Salviamo la prima release trovata.
        $tracker_tmdb{$tmdb} //= $name;
    }

    if (
        defined $imdb
        &&
        $imdb =~ /^\d+$/
        &&
        $imdb > 0
    ) {

        $tracker_imdb{$imdb} //= $name;
    }

    $torrent_count++;
}

print "Indice locale tracker:\n";
print "  Torrent       : $torrent_count\n";
print "  TMDB distinti : "
    . scalar(keys %tracker_tmdb)
    . "\n";

print "  IMDb distinti : "
    . scalar(keys %tracker_imdb)
    . "\n";

print "\n";

# ============================================================
# FALLBACK PER NOME
# Solo se l'NFO non contiene TMDB/IMDb.
# ============================================================

sub fallback_lookup {

    my ($title, $year) = @_;

    my %params = (
        'categories[]' => $category,
        'perPage'      => 1,
        'name'         => $title,
    );

    if (
        $media_type eq 'movie'
        &&
        defined $year
    ) {

        $params{startYear} = $year;
        $params{endYear}   = $year;
    }

    my ($body, $status, $error)
        = api_request_retry(%params);

    return (undef, undef, $error)
        if $error;

    my $json;

    eval {
        $json = decode_json($body);
    };

    return (
        undef,
        undef,
        'JSON fallback non valido'
    ) if $@;

    my $data = $json->{data};

    return (0, undef, undef)
        unless ref($data) eq 'ARRAY'
        && @$data;

    my $release
        = $data->[0]{attributes}{name}
        // '';

    return (
        1,
        $release,
        undef
    );
}

# ============================================================
# CONFRONTO LIBRERIA
# ============================================================

#open my $missing_fh, '>', $missing_file
#    or die "Impossibile scrivere $missing_file: $!\n";
	
my @missing_items;

my $present = 0;
my $missing = 0;
my $errors  = 0;
my $no_id   = 0;

print "Controllo libreria locale...\n\n";

for my $dir (@dirs) {

    my ($title, $year)
        = directory_title_year($dir);

    my $nfo
        = find_nfo($dir);
	#print "DEBUG NFO: " . (defined $nfo ? $nfo : 'NESSUNO') . "\n";

    my ($tmdb, $imdb)
        = parse_nfo_ids($nfo);

    my (
        $found,
        $release,
        $method
    );

    # --------------------------------------------------------
    # TMDB
    # --------------------------------------------------------

    if (
        defined $tmdb
        &&
        exists $tracker_tmdb{$tmdb}
    ) {

        $found   = 1;
        $release = $tracker_tmdb{$tmdb};
        $method  = "TMDB:$tmdb";
    }

    # --------------------------------------------------------
    # IMDb
    # --------------------------------------------------------

    elsif (
        defined $imdb
        &&
        exists $tracker_imdb{$imdb}
    ) {

        $found   = 1;
        $release = $tracker_imdb{$imdb};
        $method  = "IMDb:$imdb";
    }

    # --------------------------------------------------------
    # ID presente ma non trovato
    # --------------------------------------------------------

    elsif (
        defined $tmdb
        ||
        defined $imdb
    ) {

        $found = 0;

        if (defined $tmdb) {

            $method = "TMDB:$tmdb";
        }
        else {

            $method = "IMDb:$imdb";
        }
    }

    # --------------------------------------------------------
    # Nessun ID
    # --------------------------------------------------------

    else {

        $no_id++;

        my $display = $title;

        if (
            $media_type eq 'movie'
            &&
            defined $year
        ) {
            $display .= " ($year)";
        }

        print "[NO ID]     $display\n";
        print "            fallback API per nome...\n";

        my (
            $fallback_found,
            $fallback_release,
            $fallback_error
        ) = fallback_lookup(
            $title,
            $year
        );

        if (defined $fallback_error) {

            print "[ERROR]     $display - $fallback_error\n";

            $errors++;

            next;
        }

        $found   = $fallback_found;
        $release = $fallback_release;
        $method  = 'NAME';

        # Fallback rari, quindi qui possiamo essere conservativi.
        sleep_fractional(1);
    }

    # --------------------------------------------------------
    # OUTPUT
    # --------------------------------------------------------

    my $display = $title;

    if (
        $media_type eq 'movie'
        &&
        defined $year
    ) {
        $display .= " ($year)";
    }

    if ($found) {

        #print "[PRESENTE]  $display [$method]\n";

        if (
            defined $release
            &&
            length $release
        ) {

            #print "            -> $release\n";
        }

        $present++;
    }
    else {

        print "[MANCANTE]  $display [$method]\n";

		my $imdb_full;
	
		if (defined $imdb && $imdb ne '') {
			$imdb_full = sprintf("tt%07d", $imdb);
		}
	
		push @missing_items, {
			name     => $title,
			path     => $dir,
			tmdb_id  => defined $tmdb ? 0 + $tmdb : undef,
			tmdb_url => defined $tmdb
				? (
					$media_type eq 'movie'
						? "https://www.themoviedb.org/movie/$tmdb"
						: "https://www.themoviedb.org/tv/$tmdb"
				)
				: undef,
			imdb_id  => $imdb_full,
			imdb_url => defined $imdb_full
				? "https://www.imdb.com/title/$imdb_full/"
				: undef,
		};
	
		$missing++;
    }
}

my $missing_json_file =
    $media_type eq 'movie'
        ? 'bulk_missing_movies.json'
        : 'bulk_missing_tv.json';

open my $json_fh, '>', $missing_json_file
    or die "Impossibile scrivere $missing_json_file: $!\n";

print $json_fh JSON::PP
    ->new
    ->utf8
    ->pretty
    ->canonical
    ->encode(\@missing_items);

close $json_fh;

#close $missing_fh;

# ============================================================
# RIEPILOGO
# ============================================================

print "\n";
print "========================================\n";
print "Presenti : $present\n";
print "Mancanti : $missing\n";
print "Errori   : $errors\n";
print "Senza ID : $no_id\n";
print "========================================\n";
print "\n";
print "Mancanti salvati in:\n";
print "  $missing_json_file\n";
print "\n";
print "Cache tracker:\n";
print "  $cache_file\n";
print "\n";
