package ASGS::Mon::ATCF;

use v5.12;
use strict;
use warnings;

use Exporter qw/import/;
use File::Basename qw/basename dirname/;
use File::Find qw/find/;
use File::Spec ();
use File::Temp qw/tempdir tempfile/;
use Digest::SHA qw/sha1_hex/;
use JSON::PP qw/encode_json decode_json/;
use POSIX qw/WNOHANG setsid/;
use Text::ParseWords qw/shellwords/;
use Time::HiRes qw/time usleep/;
use Time::Local qw/timegm/;

our @EXPORT_OK = qw(
    read_assignments
    read_state
    read_properties
    parse_atcf_file
    parse_source_product
    ymdh_to_epoch
    epoch_to_ymdh
    normalize_advisory
    run_sanity_check
);

our $VERSION = q{0.1.1};

my %STATUS_CODE = (
    OK       => 0,
    WARNING  => 1,
    CRITICAL => 2,
    UNKNOWN  => 3,
);

sub _trim {
    my ($s) = @_;
    return undef if not defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub _slurp {
    my ($path) = @_;
    return undef if not defined $path or not -r $path;
    open my $fh, q{<}, $path or return undef;
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

sub _first_defined {
    for my $v (@_) {
        return $v if defined $v && $v ne q{};
    }
    return undef;
}

sub _env_seed {
    my %seed = %ENV;
    $seed{SCRIPTDIR} = $ENV{ASGS_MON_SCRIPTDIR}
        if defined $ENV{ASGS_MON_SCRIPTDIR} && $ENV{ASGS_MON_SCRIPTDIR} ne q{};
    $seed{RUNDIR} = $ENV{ASGS_MON_RUNDIR}
        if defined $ENV{ASGS_MON_RUNDIR} && $ENV{ASGS_MON_RUNDIR} ne q{};
    $seed{SYSLOG} = $ENV{ASGS_MON_SYSLOG}
        if defined $ENV{ASGS_MON_SYSLOG} && $ENV{ASGS_MON_SYSLOG} ne q{};
    return \%seed;
}

sub _safe_expand {
    my ($value, $vars) = @_;
    return undef if not defined $value;
    return undef if $value =~ /`|\$\(|<\(|>\(/;  # do not evaluate shell code

    for (1 .. 8) {
        my $before = $value;
        $value =~ s/\$\{([A-Za-z_]\w*)\}/defined($vars->{$1}) ? $vars->{$1} : "\${$1}"/ge;
        $value =~ s/\$([A-Za-z_]\w*)/defined($vars->{$1}) ? $vars->{$1} : "\$$1"/ge;
        last if $value eq $before;
    }
    if ($value =~ /^~(?=\/|$)/ && defined $ENV{HOME}) {
        $value =~ s/^~/$ENV{HOME}/;
    }
    return $value;
}

sub read_assignments {
    my ($path, $seed) = @_;
    my %vars = %{ $seed || _env_seed() };
    return \%vars if not defined $path or not -r $path;

    open my $fh, q{<}, $path or return \%vars;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        $line =~ s/^\s*export\s+//;
        next if $line !~ /^\s*([A-Za-z_]\w*)\s*=\s*(.*?)\s*$/;
        my ($key, $raw) = ($1, $2);

        # Strip only a simple trailing shell comment. Quoted # characters remain.
        if ($raw !~ /^['"]/ && $raw =~ /\s+#/) {
            $raw =~ s/\s+#.*$//;
        }
        if ($raw =~ /^'(.*)'$/s) {
            $raw = $1;
        }
        elsif ($raw =~ /^"(.*)"$/s) {
            $raw = $1;
            $raw =~ s/\\"/"/g;
            $raw =~ s/\\\\/\\/g;
        }
        my $expanded = _safe_expand($raw, \%vars);
        next if not defined $expanded;
        $vars{$key} = $expanded;
    }
    close $fh;
    return \%vars;
}

sub read_state {
    my ($path) = @_;
    my %s;
    return \%s if not defined $path or not -r $path;
    open my $fh, q{<}, $path or return \%s;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        $line =~ s/^\s*export\s+//;
        next if $line !~ /^\s*([A-Za-z_]\w*)\s*=\s*(.*?)\s*$/;
        my ($k, $v) = (lc($1), $2);
        if ($v =~ /^'(.*)'$/s || $v =~ /^"(.*)"$/s) {
            $v = $1;
        }
        $s{$k} = $v;
    }
    close $fh;
    return \%s;
}

sub read_properties {
    my ($path) = @_;
    my %p;
    return \%p if not defined $path or not -r $path;
    open my $fh, q{<}, $path or return \%p;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        next if $line !~ /^\s*([^:#][^:]*)\s*:\s*(.*?)\s*$/;
        my ($k, $v) = (_trim($1), _trim($2));
        $p{$k} = $v;
    }
    close $fh;
    return \%p;
}

sub normalize_advisory {
    my ($adv) = @_;
    return undef if not defined $adv;
    $adv = uc _trim($adv);
    return undef if $adv !~ /^(\d{1,3})([A-Z]?)$/;
    return sprintf(q{%03d%s}, 0 + $1, $2);
}

sub ymdh_to_epoch {
    my ($ymdh) = @_;
    return undef if not defined $ymdh or $ymdh !~ /^(\d{4})(\d{2})(\d{2})(\d{2})$/;
    my ($y, $m, $d, $h) = ($1, $2, $3, $4);
    return undef if $m < 1 || $m > 12 || $d < 1 || $d > 31 || $h > 23;
    my $epoch = eval { timegm(0, 0, $h, $d, $m - 1, $y) };
    return undef if $@;
    my @g = gmtime($epoch);
    my $round = sprintf(q{%04d%02d%02d%02d}, $g[5] + 1900, $g[4] + 1, $g[3], $g[2]);
    return undef if $round ne $ymdh;
    return $epoch;
}

sub epoch_to_ymdh {
    my ($epoch) = @_;
    return undef if not defined $epoch;
    my @g = gmtime($epoch);
    return sprintf(q{%04d%02d%02d%02d}, $g[5] + 1900, $g[4] + 1, $g[3], $g[2]);
}

sub parse_source_product {
    my ($text, $storm, $year) = @_;
    my @products;
    return \@products if not defined $text;

    my $plain = $text;
    $plain =~ s/&nbsp;/ /gi;
    $plain =~ s/&lt;/</gi;
    $plain =~ s/&gt;/>/gi;
    $plain =~ s/<[^>]+>/ /g;
    $plain =~ s/\r//g;

    while ($plain =~ /(?:^|\n|\s)([A-Z][A-Z0-9-]*)\s+FORECAST\s*\/\s*ADVISORY\s+NUMBER\s+(\d{1,3}[A-Z]?).{0,1000}?\bAL(\d{2})(\d{4})\b/gis) {
        my ($name, $adv_raw, $s, $y) = (uc($1), uc(_trim($2)), $3, $4);
        my $adv = normalize_advisory($adv_raw);
        push @products, {
            basin    => q{AL},
            storm    => sprintf(q{%02d}, $s),
            year     => $y,
            name     => $name,
            advisory => $adv,
            advisory_raw => $adv_raw,
            matches_config => ((defined $storm ? sprintf(q{%02d}, $storm) eq sprintf(q{%02d}, $s) : 1)
                               && (defined $year ? "$year" eq "$y" : 1)) ? 1 : 0,
        };
    }

    # Some feeds do not keep the storm name immediately adjacent. Preserve
    # advisory identity even when the name cannot be extracted.
    while ($plain =~ /FORECAST\s*\/\s*ADVISORY\s+NUMBER\s+(\d{1,3}[A-Z]?).{0,1000}?\bAL(\d{2})(\d{4})\b/gis) {
        my ($adv_raw, $s, $y) = (uc(_trim($1)), $2, $3);
        my $adv = normalize_advisory($adv_raw);
        next if grep { $_->{advisory} eq $adv && $_->{storm} eq sprintf(q{%02d}, $s) && $_->{year} eq $y } @products;
        push @products, {
            basin    => q{AL},
            storm    => sprintf(q{%02d}, $s),
            year     => $y,
            name     => undef,
            advisory => $adv,
            advisory_raw => $adv_raw,
            matches_config => ((defined $storm ? sprintf(q{%02d}, $storm) eq sprintf(q{%02d}, $s) : 1)
                               && (defined $year ? "$year" eq "$y" : 1)) ? 1 : 0,
        };
    }
    return \@products;
}

sub parse_atcf_file {
    my ($path) = @_;
    my @rows;
    my @errors;
    return { rows => [], errors => ["ATCF file '$path' is not readable"] }
        if not defined $path or not -r $path;

    open my $fh, q{<}, $path or return { rows => [], errors => ["cannot read ATCF file '$path': $!"] };
    my $line_no = 0;
    while (my $line = <$fh>) {
        ++$line_no;
        chomp $line;
        next if $line =~ /^\s*$/;
        if (length($line) < 18) {
            push @errors, "line $line_no is too short to contain an ATCF timestamp";
            next;
        }

        # ATCF is fixed-column. The timestamp occupies characters 9..18.
        my $fixed_time = substr($line, 8, 10);
        if ($fixed_time !~ /^\d{10}$/ || not defined ymdh_to_epoch($fixed_time)) {
            push @errors, "line $line_no has invalid fixed-column timestamp '$fixed_time'";
            next;
        }

        my @f = map { _trim($_) } split /,/, $line, -1;
        if (@f < 6) {
            push @errors, "line $line_no does not contain the minimum ATCF fields";
            next;
        }
        my $field_time = $f[2] // q{};
        if ($field_time ne $fixed_time) {
            push @errors, "line $line_no timestamp field '$field_time' does not match fixed-column '$fixed_time'";
            next;
        }

        my $tau = $f[5];
        $tau = undef if not defined $tau or $tau !~ /^-?\d+(?:\.\d+)?$/;
        push @rows, {
            line_no   => $line_no,
            raw       => $line,
            basin     => uc($f[0] // q{}),
            storm     => defined($f[1]) && $f[1] =~ /^\d+$/ ? sprintf(q{%02d}, $f[1]) : ($f[1] // q{}),
            ymdh      => $fixed_time,
            epoch     => ymdh_to_epoch($fixed_time),
            technique => uc($f[4] // q{}),
            tau       => $tau,
            name      => defined($f[27]) ? uc(_trim($f[27])) : undef,
        };
    }
    close $fh;

    my @ofcl = grep { $_->{technique} eq q{OFCL} } @rows;
    my %bases = map { $_->{ymdh} => 1 } @ofcl;
    my $model_time;
    my $forecast_end;
    if (@ofcl && keys(%bases) == 1) {
        ($model_time) = keys %bases;
        my $base_epoch = ymdh_to_epoch($model_time);
        for my $r (@ofcl) {
            next if not defined $r->{tau};
            my $end = $base_epoch + int($r->{tau} * 3600);
            if (!defined($forecast_end) || $end > $forecast_end) {
                $forecast_end = $end;
            }
        }
    }

    my ($name) = grep { defined $_ && $_ ne q{} } map { $_->{name} } reverse @ofcl;
    my ($storm) = grep { defined $_ && $_ ne q{} } map { $_->{storm} } @ofcl;
    my ($basin) = grep { defined $_ && $_ ne q{} } map { $_->{basin} } @ofcl;

    return {
        rows              => \@rows,
        ofcl_rows         => \@ofcl,
        errors            => \@errors,
        model_time        => $model_time,
        model_epoch       => defined($model_time) ? ymdh_to_epoch($model_time) : undef,
        forecast_end_epoch=> $forecast_end,
        forecast_end_time => defined($forecast_end) ? epoch_to_ymdh($forecast_end) : undef,
        forecast_hours    => (defined($forecast_end) && defined($model_time))
                             ? (($forecast_end - ymdh_to_epoch($model_time)) / 3600) : undef,
        storm             => $storm,
        basin             => $basin,
        name              => $name,
        base_count        => scalar(keys %bases),
    };
}

sub _parse_logged_adapter_options {
    my ($syslog) = @_;
    return {} if not defined $syslog or not -r $syslog;
    open my $fh, q{<}, $syslog or return {};
    my $size = -s $fh;
    my $window = 512 * 1024;
    if (defined($size) && $size > $window) {
        seek($fh, -$window, 2);
        scalar <$fh>; # discard a possibly partial first line
    }
    local $/;
    my $text = <$fh>;
    close $fh;
    return {} if not defined $text;
    my ($last);
    for my $line (split /\n/, $text) {
        if ($line =~ /Options for\s+(.+?)\s+are as follows\s*:\s*(--.*)$/) {
            $last = [$1, $2];
        }
    }
    return {} if not $last;
    my @tokens = eval { shellwords($last->[1]) };
    return {} if $@;
    my %v = ( GET_ATCF_SCRIPT => _trim($last->[0]) );
    while (@tokens) {
        my $opt = shift @tokens;
        next if $opt !~ /^--([a-z0-9_-]+)$/i;
        my $key = lc $1;
        my $val = @tokens && $tokens[0] !~ /^--/ ? shift @tokens : 1;
        my %map = (
            storm   => q{STORM},
            year    => q{YEAR},
            ftpsite => q{FTPSITE},
            fdir    => q{FDIR},
            hdir    => q{HDIR},
            rsssite => q{RSSSITE},
            trigger => q{TRIGGER},
            adv     => q{ADVISORY},
        );
        $v{$map{$key}} = $val if exists $map{$key};
    }
    return \%v;
}

sub _value {
    my ($key, $logged, $cfg, $state) = @_;
    my $lk = lc $key;
    return _first_defined(
        $logged->{$key},
        $ENV{$key},
        $cfg->{$key},
        $state->{$lk},
    );
}

sub _find_files {
    my ($root, $predicate, $max_depth, $limit) = @_;
    my @out;
    return \@out if not defined $root or not -d $root;
    $max_depth //= 4;
    $limit //= 100;
    my $root_depth = scalar File::Spec->splitdir(File::Spec->canonpath($root));
    find({
        no_chdir => 1,
        wanted => sub {
            return if @out >= $limit;
            my $path = $File::Find::name;
            my $depth = scalar(File::Spec->splitdir(File::Spec->canonpath($path))) - $root_depth;
            if (-d $path && $depth > $max_depth) {
                $File::Find::prune = 1;
                return;
            }
            return if not -f $path;
            push @out, $path if $predicate->($path);
        },
    }, $root);
    return \@out;
}

sub _collect_property_files {
    my ($rundir, $advisory) = @_;
    return [] if not defined $rundir or not -d $rundir;
    my %roots;
    if (defined $advisory && $advisory ne q{}) {
        my @a = ($advisory);
        if ($advisory =~ /^(\d+)([A-Za-z]?)$/) {
            push @a, sprintf(q{%02d%s}, $1, uc $2), sprintf(q{%03d%s}, $1, uc $2);
        }
        for my $a (@a) {
            my $p = File::Spec->catdir($rundir, $a);
            $roots{$p} = 1 if -d $p;
        }
    }
    # Do not recurse through the whole RUNDIR when the current advisory
    # directory is not identifiable yet: that could re-alert on an older
    # advisory's failed scenario. Top-level run.properties is still inspected.
    my %files;
    my $top_run = File::Spec->catfile($rundir, q{run.properties});
    $files{$top_run} = 1 if -f $top_run;
    for my $root (keys %roots) {
        for my $path (@{ _find_files($root, sub {
            my ($p) = @_;
            my $b = basename($p);
            return $b eq q{run.properties} || $b =~ /\.run-control\.properties$/;
        }, 4, 150) }) {
            $files{$path} = 1;
        }
    }
    return [ sort { (stat($b))[9] <=> (stat($a))[9] || $a cmp $b } keys %files ];
}

sub _find_hotstart {
    my ($lastsubdir) = @_;
    return undef if not defined $lastsubdir or not -d $lastsubdir;
    my $files = _find_files($lastsubdir, sub {
        my ($p) = @_;
        my $b = basename($p);
        return $b eq q{fort.67} || $b eq q{fort.67.nc};
    }, 4, 40);
    return undef if not @$files;
    my @sorted = sort { (stat($b))[9] <=> (stat($a))[9] } @$files;
    return $sorted[0];
}

sub _run_capture {
    my (%arg) = @_;
    my $cmd = $arg{cmd} || [];
    my $cwd = $arg{cwd};
    my $timeout = $arg{timeout} || 15;
    my ($outfh, $outfile) = tempfile();
    my ($errfh, $errfile) = tempfile();
    close $outfh;
    close $errfh;

    my $pid = fork();
    return { exit => 127, error => "fork failed: $!", stdout => q{}, stderr => q{} } if not defined $pid;
    if ($pid == 0) {
        eval { setsid() };
        chdir $cwd or POSIX::_exit(126) if defined $cwd;
        open STDOUT, q{>}, $outfile or POSIX::_exit(126);
        open STDERR, q{>}, $errfile or POSIX::_exit(126);
        exec {$cmd->[0]} @$cmd or POSIX::_exit(127);
    }

    my $deadline = time + $timeout;
    my $status;
    my $timed_out = 0;
    while (1) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) {
            $status = $?;
            last;
        }
        if (time >= $deadline) {
            $timed_out = 1;
            kill q{TERM}, -$pid;
            usleep(250_000);
            my $again = waitpid($pid, WNOHANG);
            if ($again != $pid) {
                kill q{KILL}, -$pid;
                waitpid($pid, 0);
            }
            $status = $?;
            last;
        }
        usleep(50_000);
    }

    my $stdout = _slurp($outfile) // q{};
    my $stderr = _slurp($errfile) // q{};
    unlink $outfile;
    unlink $errfile;
    my $exit = ($status & 127) ? 128 + ($status & 127) : ($status >> 8);
    return { exit => $exit, timeout => $timed_out, stdout => $stdout, stderr => $stderr };
}

sub _probe_source {
    my (%arg) = @_;
    my $script = $arg{script};
    my $base = basename($script // q{});
    my %safe = map { $_ => 1 } qw/get_atcf.pl get_atcf_http.pl/;
    return { supported => 0, reason => "configured adapter '$base' has no read-only probe contract" }
        if not $safe{$base};
    return { supported => 1, error => "configured adapter '$script' is not readable" }
        if not defined $script or not -f $script or not -r $script;

    my $tmp = tempdir(q{asgs-mon-atcf-XXXXXX}, TMPDIR => 1, CLEANUP => 1);
    my @cmd = ($^X, $script,
        q{--storm},   $arg{storm},
        q{--year},    $arg{year},
        q{--ftpsite}, $arg{ftpsite},
        q{--fdir},    $arg{fdir},
        q{--hdir},    $arg{hdir},
        q{--rsssite}, $arg{rsssite},
        q{--trigger}, $arg{trigger},
    );

    my $run = _run_capture(cmd => \@cmd, cwd => $tmp, timeout => $arg{timeout} || 15);
    my @files = @{ _find_files($tmp, sub { 1 }, 2, 100) };
    my @text_files = grep { basename($_) eq q{index-at.xml} || /\.html$/i } @files;
    my $source_text = join "\n", map { _slurp($_) // q{} } @text_files;

    my $fst = File::Spec->catfile($tmp, sprintf(q{al%02d%s.fst}, $arg{storm}, $arg{year}));
    my $html = "$fst.html";
    my $metadata = File::Spec->catfile($tmp, q{forecast.properties});

    # Stock ASGS invokes nhc_advisory_bot.pl after get_atcf*.pl for RSS modes.
    # Reproduce that transformation in the private sandbox only.
    if (not -s $fst && -s $html) {
        my $bot = File::Spec->catfile($arg{scriptdir}, q{nhc_advisory_bot.pl});
        if (-f $bot && -r $bot) {
            my @botcmd = ($^X, $bot, q{--input}, $html, q{--output}, $fst, q{--metadata}, $metadata);
            my $botrun = _run_capture(cmd => \@botcmd, cwd => $tmp, timeout => $arg{timeout} || 15);
            $run->{bot} = $botrun;
        }
    }

    my $atcf = -s $fst ? parse_atcf_file($fst) : undef;
    my $products = parse_source_product($source_text, $arg{storm}, $arg{year});
    my ($adapter_adv, $adapter_adv_raw);
    my $combined = ($run->{stdout} // q{}) . "\n" . ($run->{stderr} // q{});
    if ($combined =~ /Advisory\s+'?(\d{1,3}[A-Z]?)'?/i) {
        $adapter_adv_raw = uc _trim($1);
        $adapter_adv = normalize_advisory($adapter_adv_raw);
    }
    elsif (($run->{stdout} // q{}) =~ /^\s*(\d{1,3}[A-Z]?)\s*$/m) {
        $adapter_adv_raw = uc _trim($1);
        $adapter_adv = normalize_advisory($adapter_adv_raw);
    }

    return {
        supported        => 1,
        tempdir          => $tmp,
        command          => \@cmd,
        exit             => $run->{exit},
        timeout          => $run->{timeout} ? 1 : 0,
        stdout           => $run->{stdout},
        stderr           => $run->{stderr},
        products         => $products,
        adapter_advisory => $adapter_adv,
        adapter_advisory_raw => $adapter_adv_raw,
        atcf             => $atcf,
        fst_present      => -s $fst ? 1 : 0,
        metadata         => -s $metadata ? read_properties($metadata) : {},
    };
}

sub _history_path {
    my (%arg) = @_;
    my $tmp = $ENV{ASGS_TMPDIR};
    $tmp = File::Spec->tmpdir if !defined($tmp) || !-d $tmp;

    # Never put monitor bookkeeping into the active RUNDIR even if an unusual
    # profile points ASGS_TMPDIR there.
    if (defined($arg{rundir}) && $arg{rundir} ne q{}) {
        my $rt = File::Spec->rel2abs($arg{rundir});
        my $tt = File::Spec->rel2abs($tmp);
        if ($tt eq $rt || index($tt, $rt . q{/}) == 0) {
            $tmp = File::Spec->tmpdir;
        }
    }
    my $identity = join q{|}, ($arg{config} // q{}), ($arg{coldstart} // q{unknown});
    return File::Spec->catfile($tmp, q{asgs-mon-atcf-} . sha1_hex($identity) . q{.history.json});
}

sub _read_json_file {
    my ($path) = @_;
    my $raw = _slurp($path);
    return undef if not defined $raw;
    my $v = eval { decode_json($raw) };
    return ref($v) eq q{HASH} ? $v : undef;
}

sub _atomic_json_file {
    my ($path, $data) = @_;
    return if not defined $path;
    my $tmp = "$path.$$";
    if (open my $fh, q{>}, $tmp) {
        print {$fh} JSON::PP->new->canonical->encode($data), "\n";
        close $fh;
        rename $tmp, $path or unlink $tmp;
    }
}

sub _add_issue {
    my ($issues, $severity, $id, $message, %extra) = @_;
    push @$issues, { severity => $severity, id => $id, message => $message, %extra };
}

sub _worst_status {
    my ($issues) = @_;
    my %rank = (INFO => 0, OK => 0, WARNING => 1, UNKNOWN => 2, CRITICAL => 3);
    my $worst = q{OK};
    for my $i (@$issues) {
        $worst = $i->{severity} if ($rank{$i->{severity}} // 0) > ($rank{$worst} // 0);
    }
    return $worst;
}

sub _scenario_label {
    my ($path) = @_;
    my $base = basename($path // q{});
    return $1 if $base =~ /^(.+)\.run-control\.properties$/;
    return basename(dirname($path)) if $base eq q{run.properties};
    return $base || q{scenario};
}

sub _fmt_signature_value {
    my ($v) = @_;
    return q{-} if not defined $v;
    return sprintf(q{%.6f}, $v) if $v =~ /^-?\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?$/;
    return "$v";
}

sub _scenario_summary {
    my ($scenarios) = @_;
    my %groups;
    for my $s (@{ $scenarios || [] }) {
        my $sig = join q{|},
            map { _fmt_signature_value($_) }
            ($s->{run_start}, $s->{run_end}, $s->{adcirc_remaining_seconds}, $s->{rnday});
        my $g = $groups{$sig} ||= {
            run_start => $s->{run_start},
            run_end => $s->{run_end},
            adcirc_remaining_seconds => $s->{adcirc_remaining_seconds},
            rnday => $s->{rnday},
            dt => $s->{dt},
            scenarios => [],
            paths => [],
        };
        $g->{dt} = $s->{dt} if not defined($g->{dt}) && defined($s->{dt});
        push @{ $g->{scenarios} }, $s->{scenario} if defined $s->{scenario};
        push @{ $g->{paths} }, $s->{path} if defined $s->{path};
    }

    my @out;
    for my $g (values %groups) {
        my %seen;
        $g->{scenarios} = [ sort grep { defined($_) && $_ ne q{} && !$seen{$_}++ } @{ $g->{scenarios} } ];
        $g->{source_count} = scalar @{ $g->{paths} };
        push @out, $g;
    }
    return [
        sort {
            join(q{,}, @{ $a->{scenarios} }) cmp join(q{,}, @{ $b->{scenarios} })
            || ($a->{run_start} // q{}) cmp ($b->{run_start} // q{})
            || ($a->{run_end} // q{}) cmp ($b->{run_end} // q{})
        } @out
    ];
}

sub _aggregate_scenario_issues {
    my ($issues) = @_;
    my %groups;
    my @order;
    my @other;
    for my $i (@{ $issues || [] }) {
        if (!defined($i->{scenario}) || $i->{scenario} eq q{}) {
            push @other, { %$i };
            next;
        }
        my $key = join q{|}, ($i->{severity} // q{}), ($i->{id} // q{});
        if (!exists $groups{$key}) {
            $groups{$key} = {
                severity => $i->{severity},
                id => $i->{id},
                scenarios => [],
                paths => [],
                remaining_seconds => [],
                guard_seconds => [],
            };
            push @order, $key;
        }
        my $g = $groups{$key};
        push @{ $g->{scenarios} }, $i->{scenario};
        push @{ $g->{paths} }, $i->{path} if defined $i->{path};
        push @{ $g->{remaining_seconds} }, $i->{remaining_seconds} if defined $i->{remaining_seconds};
        push @{ $g->{guard_seconds} }, $i->{guard_seconds} if defined $i->{guard_seconds};
    }

    my @out = @other;
    for my $key (@order) {
        my $g = $groups{$key};
        my %seen;
        my @names = sort grep { !$seen{$_}++ } @{ $g->{scenarios} };
        my $where = join(q{, }, @names);
        my $msg;
        if ($g->{id} eq q{run_end_not_after_start}) {
            $msg = "RunEndTime is not after RunStartTime in: $where";
        }
        elsif ($g->{id} eq q{rnday_2dt_guard}) {
            my $min = @{ $g->{remaining_seconds} }
                ? (sort { $a <=> $b } @{ $g->{remaining_seconds} })[0] : undef;
            my $guard = @{ $g->{guard_seconds} }
                ? (sort { $b <=> $a } @{ $g->{guard_seconds} })[0] : undef;
            $msg = "rnday reaches the ADCIRC 2*dt safeguard in: $where";
            $msg .= sprintf(q{ (minimum remaining %.3fs; 2*dt %.3fs)}, $min, $guard)
                if defined($min) && defined($guard);
        }
        elsif ($g->{id} eq q{forecast_duration_tiny}) {
            my $min = @{ $g->{remaining_seconds} }
                ? (sort { $a <=> $b } @{ $g->{remaining_seconds} })[0] : undef;
            $msg = "ADCIRC remaining forecast duration is under 60 seconds in: $where";
            $msg .= sprintf(q{ (minimum %.3fs)}, $min) if defined $min;
        }
        elsif ($g->{id} eq q{rnday_exhausted}) {
            $msg = "rnday leaves no forecast time after hotstart in: $where";
        }
        elsif ($g->{id} eq q{run_time_malformed}) {
            $msg = "RunStartTime/RunEndTime is incomplete or malformed in: $where";
        }
        else {
            $msg = "$g->{id} affects: $where";
        }
        push @out, {
            severity => $g->{severity},
            id => $g->{id},
            message => $msg,
            scenarios => \@names,
            paths => $g->{paths},
        };
    }
    return \@out;
}

sub _scenario_assessments {
    my (%arg) = @_;
    my @scenarios;
    my @issues;
    my $files = _collect_property_files($arg{rundir}, $arg{advisory});
    my $default_dt = $arg{timestepsize};

    for my $path (@$files) {
        my $p = read_properties($path);
        next if not exists($p->{RunStartTime}) && not exists($p->{RunEndTime})
             && not exists($p->{q{adcirc.control.physics.rnday}});
        my $start = $p->{RunStartTime};
        my $end   = $p->{RunEndTime};
        my $start_epoch = ymdh_to_epoch($start);
        my $end_epoch   = ymdh_to_epoch($end);
        my $dt = _first_defined($p->{q{adcirc.timestepsize}}, $default_dt);
        $dt = undef if defined($dt) && $dt !~ /^\d+(?:\.\d+)?$/;
        my $rnday = $p->{q{adcirc.control.physics.rnday}};
        $rnday = undef if defined($rnday) && $rnday !~ /^-?\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?$/;
        my $ihs = $p->{InitialHotStartTime};
        $ihs = 0 if not defined($ihs) || $ihs !~ /^\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?$/;

        my $scenario = _scenario_label($path);
        my $item = {
            path => $path,
            scenario => $scenario,
            run_start => $start,
            run_end => $end,
            rnday => defined($rnday) ? 0 + $rnday : undef,
            initial_hotstart_seconds => 0 + $ihs,
            dt => defined($dt) ? 0 + $dt : undef,
        };
        if (defined $start_epoch && defined $end_epoch) {
            $item->{duration_seconds} = $end_epoch - $start_epoch;
            if ($end_epoch <= $start_epoch) {
                _add_issue(\@issues, q{CRITICAL}, q{run_end_not_after_start},
                    "$scenario: RunEndTime=$end is not after RunStartTime=$start",
                    path => $path, scenario => $scenario, run_start => $start, run_end => $end);
            }
        }
        elsif ((defined($start) && $start ne q{}) || (defined($end) && $end ne q{})) {
            _add_issue(\@issues, q{WARNING}, q{run_time_malformed},
                "$scenario: RunStartTime/RunEndTime is incomplete or malformed",
                path => $path, scenario => $scenario);
        }

        if (defined $rnday) {
            my $remaining = (0 + $rnday) * 86400 - (0 + $ihs);
            $item->{adcirc_remaining_seconds} = $remaining;
            if ($remaining <= 0) {
                _add_issue(\@issues, q{CRITICAL}, q{rnday_exhausted},
                    sprintf(q{%s: rnday leaves %.3f seconds after hotstart (must be > 0)}, $scenario, $remaining),
                    path => $path, scenario => $scenario, remaining_seconds => 0 + $remaining);
            }
            if (defined $dt && $remaining <= (2 * $dt + 0.001)) {
                _add_issue(\@issues, q{CRITICAL}, q{rnday_2dt_guard},
                    sprintf(q{%s: rnday leaves %.3f seconds after hotstart, <= 2*dt (%.3f s)}, $scenario, $remaining, 2 * $dt),
                    path => $path, scenario => $scenario, remaining_seconds => 0 + $remaining, guard_seconds => 0 + (2 * $dt));
            }
            if ($remaining > 0 && $remaining < 60) {
                _add_issue(\@issues, q{CRITICAL}, q{forecast_duration_tiny},
                    sprintf(q{%s: ADCIRC remaining forecast duration is only %.3f seconds}, $scenario, $remaining),
                    path => $path, scenario => $scenario, remaining_seconds => 0 + $remaining);
            }
        }
        push @scenarios, $item;
    }
    return (\@scenarios, \@issues);
}

sub _hotstart_context {
    my (%arg) = @_;
    my $path = _find_hotstart($arg{lastsubdir});
    my $hstime = $arg{state}->{hstime};
    my $source = ($arg{expected} || defined($path))
        && defined($hstime) && $hstime =~ /^\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?$/ ? q{state} : undef;
    $hstime = undef if not defined($source);

    if (defined $path) {
        my $hstime_bin = $arg{hstime_bin};
        if (defined $hstime_bin && -x $hstime_bin) {
            my @cmd = ($hstime_bin, q{-f}, $path);
            push @cmd, q{-n} if $path =~ /\.nc$/i;
            my $r = _run_capture(cmd => \@cmd, cwd => dirname($path), timeout => 8);
            if (!$r->{timeout} && $r->{exit} == 0 && ($r->{stdout} // q{}) =~ /(-?\d+(?:\.\d+)?(?:[Ee][+-]?\d+)?)/) {
                $hstime = 0 + $1;
                $source = q{hstime};
            }
        }
    }

    my $cold = $arg{coldstart};
    my $cold_epoch = ymdh_to_epoch($cold);
    my $model_epoch = defined($cold_epoch) && defined($hstime) ? $cold_epoch + $hstime : undef;

    my $producer_cold;
    if (defined $path) {
        my @candidates = (
            File::Spec->catfile(dirname($path), q{run.properties}),
            File::Spec->catfile(dirname(dirname($path)), q{run.properties}),
            File::Spec->catfile($arg{lastsubdir}, q{run.properties}),
        );
        for my $p (@candidates) {
            next if not -r $p;
            my $rp = read_properties($p);
            if (defined $rp->{ColdStartTime}) {
                $producer_cold = $rp->{ColdStartTime};
                last;
            }
        }
    }

    return {
        path => $path,
        hstime_seconds => defined($hstime) ? 0 + $hstime : undef,
        hstime_source => $source,
        model_epoch => $model_epoch,
        model_time => defined($model_epoch) ? epoch_to_ymdh($model_epoch) : undef,
        producer_cold_start => $producer_cold,
    };
}

sub run_sanity_check {
    my (%arg) = @_;
    my @issues;
    my @notes;

    my $config = $arg{config} // $ENV{ASGS_MON_CONFIG} // $ENV{ASGS_CONFIG};
    my $statefile = $arg{statefile} // $ENV{ASGS_MON_STATEFILE} // $ENV{STATEFILE};
    my $rundir = $arg{rundir} // $ENV{ASGS_MON_RUNDIR} // $ENV{RUNDIR};
    my $syslog = $arg{syslog} // $ENV{ASGS_MON_SYSLOG} // $ENV{SYSLOG};
    my $scriptdir = $arg{scriptdir} // $ENV{ASGS_MON_SCRIPTDIR} // $ENV{SCRIPTDIR};
    my $lastsubdir = $arg{lastsubdir} // $ENV{ASGS_MON_LASTSUBDIR} // $ENV{LASTSUBDIR};

    my $state = read_state($statefile);
    my $cfg = read_assignments($config, _env_seed());
    my $logged = _parse_logged_adapter_options($syslog);

    my $tc = _first_defined($ENV{TROPICALCYCLONE}, $cfg->{TROPICALCYCLONE}, $state->{tropicalcyclone});
    if (defined($tc) && lc($tc) ne q{on}) {
        return {
            status => q{OK}, status_code => 0, applicable => JSON::PP::false,
            summary => "TROPICALCYCLONE=$tc; ATCF sanity check not applicable",
            issues => [], notes => [],
        };
    }
    if (not defined $tc) {
        _add_issue(\@issues, q{UNKNOWN}, q{tc_mode_unknown}, q{TROPICALCYCLONE could not be determined from the loaded configuration});
    }

    my %v;
    for my $k (qw/STORM YEAR TRIGGER RSSSITE FTPSITE FDIR HDIR GET_ATCF_SCRIPT/) {
        $v{$k} = _value($k, $logged, $cfg, $state);
    }
    $v{STORM} = sprintf(q{%02d}, $v{STORM}) if defined($v{STORM}) && $v{STORM} =~ /^\d+$/;
    $v{TRIGGER} //= q{rss};

    if ((!defined($v{GET_ATCF_SCRIPT}) || $v{GET_ATCF_SCRIPT} eq q{}) && defined $scriptdir) {
        my $default_adapter = File::Spec->catfile($scriptdir, q{get_atcf.pl});
        $v{GET_ATCF_SCRIPT} = $default_adapter if -r $default_adapter;
    }

    for my $k (qw/STORM YEAR RSSSITE FTPSITE FDIR HDIR GET_ATCF_SCRIPT/) {
        _add_issue(\@issues, q{CRITICAL}, q{config_missing}, "$k is not available from the active ASGS configuration/runtime")
            if not defined($v{$k}) || $v{$k} eq q{};
    }

    if (defined $v{GET_ATCF_SCRIPT} && $v{GET_ATCF_SCRIPT} ne q{}) {
        $v{GET_ATCF_SCRIPT} = _safe_expand($v{GET_ATCF_SCRIPT}, { %$cfg, SCRIPTDIR => $scriptdir });
        if (defined($v{GET_ATCF_SCRIPT}) && !File::Spec->file_name_is_absolute($v{GET_ATCF_SCRIPT}) && defined $scriptdir) {
            $v{GET_ATCF_SCRIPT} = File::Spec->catfile($scriptdir, $v{GET_ATCF_SCRIPT});
        }
    }

    my $probe;
    if (!grep { $_->{severity} eq q{CRITICAL} && $_->{id} eq q{config_missing} } @issues) {
        $probe = _probe_source(
            script => $v{GET_ATCF_SCRIPT}, scriptdir => $scriptdir,
            storm => $v{STORM}, year => $v{YEAR}, trigger => $v{TRIGGER},
            rsssite => $v{RSSSITE}, ftpsite => $v{FTPSITE}, fdir => $v{FDIR}, hdir => $v{HDIR},
            timeout => $arg{probe_timeout} || ($ENV{ASGS_MON_ATCF_PROBE_TIMEOUT} || 15),
        );
        if (!$probe->{supported}) {
            _add_issue(\@issues, q{UNKNOWN}, q{adapter_probe_unsupported}, $probe->{reason});
        }
        elsif ($probe->{timeout}) {
            _add_issue(\@issues, q{CRITICAL}, q{adapter_timeout}, "configured ATCF adapter timed out while probing the source");
        }
        elsif (defined $probe->{error}) {
            _add_issue(\@issues, q{CRITICAL}, q{adapter_unreadable}, $probe->{error});
        }
        elsif ($probe->{exit} != 0) {
            my $why = _trim($probe->{stderr}) || "exit $probe->{exit}";
            $why =~ s/\s+/ /g;
            $why = substr($why, 0, 300);
            _add_issue(\@issues, q{CRITICAL}, q{adapter_failed}, "configured ATCF adapter failed: $why");
        }
        elsif (!$probe->{fst_present} || !$probe->{atcf}) {
            _add_issue(\@issues, q{CRITICAL}, q{atcf_missing}, q{adapter probe did not yield a usable OFCL ATCF forecast in the private sandbox});
        }
    }

    my $source = {};
    if ($probe && $probe->{atcf}) {
        my $a = $probe->{atcf};
        if (@{ $a->{errors} || [] }) {
            _add_issue(\@issues, q{CRITICAL}, q{atcf_malformed}, join(q{; }, @{ $a->{errors} }));
        }
        if (!@{ $a->{ofcl_rows} || [] }) {
            _add_issue(\@issues, q{CRITICAL}, q{atcf_no_ofcl}, q{ATCF source contains no usable OFCL records});
        }
        if (($a->{base_count} // 0) > 1) {
            _add_issue(\@issues, q{CRITICAL}, q{atcf_multiple_model_times}, q{OFCL forecast contains multiple advisory/model base timestamps});
        }
        if (defined($a->{storm}) && $a->{storm} ne $v{STORM}) {
            _add_issue(\@issues, q{CRITICAL}, q{storm_mismatch}, "ATCF source is storm $a->{storm}; ASGS is configured for $v{STORM}");
        }
        if (defined($a->{model_epoch}) && defined($a->{forecast_end_epoch}) && $a->{forecast_end_epoch} <= $a->{model_epoch}) {
            _add_issue(\@issues, q{CRITICAL}, q{forecast_end_not_after_advisory},
                "ATCF forecast end " . ($a->{forecast_end_time} // q{unknown}) . " is not after advisory/model time " . ($a->{model_time} // q{unknown}));
        }

        my ($product) = grep { $_->{matches_config} } @{ $probe->{products} || [] };
        if (!$product && @{ $probe->{products} || [] }) {
            my $p = $probe->{products}->[0];
            _add_issue(\@issues, q{CRITICAL}, q{rss_storm_mismatch},
                "Forecast/Advisory product identifies AL$p->{storm}$p->{year}, not configured AL$v{STORM}$v{YEAR}");
        }
        my $product_adv = $product ? $product->{advisory} : undef;
        my $product_adv_raw = $product ? $product->{advisory_raw} : undef;
        my $adapter_adv = $probe->{adapter_advisory};
        my $adapter_adv_raw = $probe->{adapter_advisory_raw};
        if (defined($product_adv) && $product_adv =~ /[A-Z]$/ && defined($adapter_adv)
            && $adapter_adv !~ /[A-Z]$/ && substr($product_adv, 0, 3) eq substr($adapter_adv, 0, 3)) {
            push @notes, "adapter advisory precision is limited: source reports $product_adv but adapter reports $adapter_adv";
        }

        $source = {
            basin => $a->{basin} || q{AL},
            storm => $a->{storm} || $v{STORM},
            year => 0 + $v{YEAR},
            name => _first_defined($product ? $product->{name} : undef, $a->{name}),
            product_advisory => $product_adv,
            product_advisory_raw => $product_adv_raw,
            adapter_advisory => $adapter_adv,
            adapter_advisory_raw => $adapter_adv_raw,
            model_time => $a->{model_time},
            model_epoch => $a->{model_epoch},
            forecast_end_time => $a->{forecast_end_time},
            forecast_end_epoch => $a->{forecast_end_epoch},
            forecast_hours => $a->{forecast_hours},
        };
    }

    my $advisory = _first_defined($state->{advisory}, $state->{cycle}, $ENV{ASGS_MON_ADVISORY}, $ENV{ADVISORY});
    my $coldstart = _first_defined($state->{coldstartdate}, $cfg->{COLDSTARTDATE}, $cfg->{CSDATE});

    my $history_path = _history_path(config => $config, coldstart => $coldstart, rundir => $rundir);
    my $previous_source = _read_json_file($history_path);
    my $source_identity = _first_defined($source->{product_advisory}, $source->{adapter_advisory});
    my $reset_state = !defined($advisory) || $advisory eq q{} || $advisory =~ /^(?:0+|initialize|null)$/i;
    my $source_is_usable = defined($source->{model_epoch}) && defined($source_identity)
        && !grep { $_->{severity} eq q{CRITICAL} && $_->{id} =~ /^(?:adapter_|atcf_|storm_|rss_)/ } @issues;
    if ($source_is_usable && $previous_source && !$reset_state
        && defined($previous_source->{advisory}) && defined($previous_source->{model_epoch})
        && $previous_source->{advisory} ne $source_identity
        && $source->{model_epoch} <= $previous_source->{model_epoch}) {
        _add_issue(\@issues, q{CRITICAL}, q{advisory_time_not_advancing},
            "source advanced from advisory $previous_source->{advisory} to $source_identity but model time did not advance "
            . "($previous_source->{model_time} -> $source->{model_time})");
    }
    if ($source_is_usable
        && !grep { $_->{id} eq q{advisory_time_not_advancing} } @issues) {
        _atomic_json_file($history_path, {
            schema => 1, advisory => $source_identity, model_time => $source->{model_time},
            model_epoch => 0 + $source->{model_epoch}, observed_epoch => time,
            storm => $source->{storm}, year => $source->{year},
        });
    }
    my $hindcast = _first_defined($state->{hindcastlength}, $cfg->{HINDCASTLENGTH});
    my $timestepsize = _first_defined($cfg->{TIMESTEPSIZE}, $state->{timestepsize});

    my ($scenarios, $scenario_issues) = _scenario_assessments(
        rundir => $rundir, advisory => $advisory, timestepsize => $timestepsize,
    );
    my $scenario_summary = _scenario_summary($scenarios);
    my $scenario_assessments = _aggregate_scenario_issues($scenario_issues);
    push @issues, @$scenario_assessments;

    # Fill missing coldstart/hindcast from the newest run.properties evidence.
    for my $s (@$scenarios) {
        my $p = read_properties($s->{path});
        $coldstart = _first_defined($coldstart, $p->{ColdStartTime});
        $hindcast = _first_defined($hindcast, $p->{q{forcing.spinup.length}});
    }

    my $adcircdir = _first_defined($cfg->{ADCIRCDIR}, $ENV{ADCIRCDIR});
    my $hstime_bin = defined($adcircdir) ? File::Spec->catfile($adcircdir, q{hstime}) : undef;
    if ((!defined($hstime_bin) || !-x $hstime_bin)) {
        for my $d (File::Spec->path) {
            my $p = File::Spec->catfile($d, q{hstime});
            if (-x $p) { $hstime_bin = $p; last; }
        }
    }
    my $hot_mode = _first_defined($state->{hotcoldstart}, $state->{hotorcold}, $state->{start}, $cfg->{HOTCOLDSTART});
    my $hotstart_expected = (defined($hot_mode) && $hot_mode =~ /hotstart/i)
        || (defined($lastsubdir) && $lastsubdir ne q{} && lc($lastsubdir) ne q{null} && -d $lastsubdir);
    my $hotstart = _hotstart_context(
        lastsubdir => $lastsubdir, state => $state, coldstart => $coldstart,
        hstime_bin => $hstime_bin, expected => $hotstart_expected,
    );
    $hotstart->{expected} = $hotstart_expected ? JSON::PP::true : JSON::PP::false;

    if ($hotstart_expected && not defined($hotstart->{hstime_seconds})) {
        _add_issue(\@issues, q{UNKNOWN}, q{hotstart_time_unknown},
            q{a hotstart/reused-run context is indicated, but its HSTIME could not be determined read-only});
    }

    if (defined($hotstart->{producer_cold_start}) && defined($coldstart)
        && $hotstart->{producer_cold_start} ne $coldstart) {
        _add_issue(\@issues, q{WARNING}, q{hotstart_coldstart_mismatch},
            "hotstart was produced with ColdStartTime=$hotstart->{producer_cold_start}, current COLDSTARTDATE=$coldstart");
    }
    if (defined($hotstart->{model_epoch}) && defined($source->{model_epoch})
        && $hotstart->{model_epoch} > $source->{model_epoch} + 300) {
        my $delta_h = ($hotstart->{model_epoch} - $source->{model_epoch}) / 3600;
        _add_issue(\@issues, q{CRITICAL}, q{hotstart_after_advisory},
            sprintf(q{ADCIRC hotstart model clock %s is %.2fh after ATCF advisory/model time %s},
                $hotstart->{model_time}, $delta_h, $source->{model_time}));
    }

    my $timeline = {};
    if (defined($source->{model_epoch}) && defined($hotstart->{model_epoch})) {
        my $delta = $source->{model_epoch} - $hotstart->{model_epoch};
        $timeline->{hotstart_to_advisory_seconds} = 0 + $delta;
        $timeline->{hotstart_to_advisory_hours} = 0 + ($delta / 3600);
        $timeline->{hotstart_before_advisory} = $delta >= 0 ? JSON::PP::true : JSON::PP::false;
        $timeline->{relation} = $delta > 0 ? q{hotstart_before_advisory}
                              : $delta < 0 ? q{hotstart_after_advisory}
                              : q{hotstart_at_advisory};
        if ($delta > 0) {
            _add_issue(\@issues, q{INFO}, q{hotstart_before_advisory},
                sprintf(q{hotstart model clock is %.3fh before ATCF advisory/model time; nowcast advance is required and this is not a failure by itself},
                    $delta / 3600));
        }
    }
    if (defined($source->{forecast_end_epoch}) && defined($source->{model_epoch})) {
        $timeline->{advisory_to_forecast_end_seconds} =
            0 + ($source->{forecast_end_epoch} - $source->{model_epoch});
        $timeline->{advisory_to_forecast_end_hours} =
            0 + (($source->{forecast_end_epoch} - $source->{model_epoch}) / 3600);
    }

    # Relative source freshness only: never compare ATCF timestamps to wall clock.
    my @valid_run_starts = grep { defined $_ } map { ymdh_to_epoch($_->{run_start}) } @$scenarios;
    if (defined($source->{model_epoch}) && @valid_run_starts) {
        my $latest_start = (sort { $b <=> $a } @valid_run_starts)[0];
        if ($source->{model_epoch} + 300 < $latest_start) {
            _add_issue(\@issues, q{WARNING}, q{source_behind_asgs_model},
                "ATCF source model time $source->{model_time} is behind the model time already represented by current ASGS scenario properties " . epoch_to_ymdh($latest_start));
        }
    }

    my $state_adv = normalize_advisory($advisory);
    if (defined($state_adv) && defined($source->{product_advisory})) {
        if ($state_adv ne $source->{product_advisory}) {
            push @notes, "ASGS state advisory=$state_adv; source product advisory=$source->{product_advisory}; model-time checks are authoritative";
        }
    }

    if (defined($hindcast) && $hindcast =~ /^\d+(?:\.\d+)?$/ && defined($coldstart) && defined ymdh_to_epoch($coldstart)) {
        my $anchor = ymdh_to_epoch($coldstart) + $hindcast * 86400;
        push @notes, sprintf(q{coldstart + hindcast anchor: %s + %.3fd = %s}, $coldstart, $hindcast, epoch_to_ymdh($anchor));
    }
    push @notes, q{wall-clock age is intentionally not assessed; ATCF/replay health is judged by relative model-time invariants};

    my $status = _worst_status(\@issues);
    my $summary;
    if ($status eq q{OK}) {
        if (defined $source->{model_time} && defined $source->{forecast_end_time}) {
            my $id = join q{}, q{AL}, ($source->{storm} // $v{STORM}), ($source->{year} // $v{YEAR});
            my $name = $source->{name} ? " $source->{name}" : q{};
            my $adv = $source->{product_advisory} // $source->{adapter_advisory} // q{?};
            $summary = sprintf(q{ATCF timeline: %s%s %s %s -> %s (+%.1fh)},
                $id, $name, $adv, $source->{model_time}, $source->{forecast_end_time}, $source->{forecast_hours} // 0);
        }
        else {
            $summary = q{ATCF/local timeline check completed without demonstrated inconsistency};
        }
    }
    else {
        my ($worst) = grep { $_->{severity} eq $status } @issues;
        $summary = $worst ? $worst->{message} : q{ATCF sanity check found an inconsistency};
    }

    return {
        schema => 1,
        type => q{atcf_sanity},
        applicable => JSON::PP::true,
        status => $status,
        status_code => $STATUS_CODE{$status},
        summary => $summary,
        config => {
            tropicalcyclone => $tc,
            storm => $v{STORM}, year => $v{YEAR}, trigger => $v{TRIGGER},
            rsssite => $v{RSSSITE}, ftpsite => $v{FTPSITE}, fdir => $v{FDIR}, hdir => $v{HDIR},
            adapter => $v{GET_ATCF_SCRIPT},
        },
        source => $source,
        asgs => {
            advisory => $state_adv || $advisory,
            advisory_raw => defined($advisory) ? _trim($advisory) : undef,
            cycle => _first_defined($state->{cycle}, $advisory),
            cold_start => $coldstart,
            hindcast_days => defined($hindcast) && $hindcast =~ /^\d+(?:\.\d+)?$/ ? 0 + $hindcast : $hindcast,
            rundir => $rundir,
        },
        hotstart => $hotstart,
        timeline => $timeline,
        scenarios => $scenarios,
        scenario_summary => $scenario_summary,
        scenario_issues => $scenario_issues,
        previous_source => $previous_source,
        issues => \@issues,
        notes => \@notes,
    };
}

1;
